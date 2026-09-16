//! Cursor approval persistence and cross-process UI reconciliation ordering.
//!
//! Pending entries must survive generic state pruning: the next lifecycle
//! callback returns their notification keys and leaves a correlation fence.
//! Otherwise a late completion could clear a newer approval for the same command.

use super::*;
use sha2::{Digest, Sha256};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::time::{Duration, Instant};

const MAX_PENDING_APPROVALS: usize = 16;
const MAX_COMMAND_BYTES: usize = 64 * 1024;
const MAX_APPROVAL_AGE: f64 = 60.0 * 60.0;
const MAX_CLEARED_FINGERPRINTS: usize = 16;
const MAX_CLEARED_AGE: f64 = 10.0 * 60.0;
const MAX_INDEX_ENTRIES: usize = 256;

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingCursorShellApproval {
    pub command_fingerprint: String,
    pub command_length: i64,
    pub display_command: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_use_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notification_correlation_key: Option<String>,
    pub created_at: f64,
    pub requires_tool_use_id: bool,
}

impl<'de> Deserialize<'de> for PendingCursorShellApproval {
    fn deserialize<D: serde::Deserializer<'de>>(decoder: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Stored {
            command_fingerprint: Option<String>,
            command_length: Option<i64>,
            display_command: Option<String>,
            command: Option<String>,
            tool_use_id: Option<String>,
            notification_correlation_key: Option<String>,
            created_at: Option<f64>,
            requires_tool_use_id: Option<bool>,
        }
        let stored = Stored::deserialize(decoder)?;
        let (command_fingerprint, command_length, display_command) =
            match (stored.command_fingerprint, stored.command_length) {
                (Some(fingerprint), Some(length)) => {
                    (fingerprint, length, stored.display_command.unwrap_or_default())
                }
                _ => {
                    let command = normalize_command(stored.command.as_deref().unwrap_or_default());
                    let (fingerprint, length) = Self::identity(&command);
                    (fingerprint, length, "Approval needed".into())
                }
            };
        Ok(Self {
            command_fingerprint,
            command_length,
            display_command,
            tool_use_id: stored.tool_use_id,
            notification_correlation_key: Some(correlation_key(
                stored.notification_correlation_key.as_deref(),
            )),
            created_at: stored.created_at.unwrap_or_default(),
            requires_tool_use_id: stored.requires_tool_use_id.unwrap_or_default(),
        })
    }
}

impl PendingCursorShellApproval {
    pub fn from_command(
        command: &str,
        tool_use_id: Option<String>,
        created_at: f64,
        requires_tool_use_id: bool,
    ) -> Self {
        Self::from_command_with_correlation(
            command,
            tool_use_id,
            created_at,
            requires_tool_use_id,
            None,
        )
    }

    fn from_command_with_correlation(
        command: &str,
        tool_use_id: Option<String>,
        created_at: f64,
        requires_tool_use_id: bool,
        notification_correlation_key: Option<&str>,
    ) -> Self {
        let command = normalize_command(command);
        let (command_fingerprint, command_length) = Self::identity(&command);
        Self {
            command_fingerprint,
            command_length,
            display_command: "Approval needed".into(),
            tool_use_id,
            notification_correlation_key: Some(correlation_key(notification_correlation_key)),
            created_at,
            requires_tool_use_id,
        }
    }

    pub fn identity(normalized_command: &str) -> (String, i64) {
        let digest = Sha256::digest(normalized_command.as_bytes());
        (
            digest.iter().map(|byte| format!("{byte:02x}")).collect(),
            normalized_command.len() as i64,
        )
    }
}

fn correlation_key(value: Option<&str>) -> String {
    value
        .filter(|value| {
            value.len() == 36
                && value.bytes().enumerate().all(|(index, byte)| {
                    if matches!(index, 8 | 13 | 18 | 23) {
                        byte == b'-'
                    } else {
                        byte.is_ascii_hexdigit()
                    }
                })
        })
        .and_then(|value| Uuid::parse_str(value).ok())
        .unwrap_or_else(Uuid::new_v4)
        .to_string()
}

fn normalize_command(command: &str) -> String {
    command.replace("\r\n", "\n").replace('\r', "\n").trim().to_owned()
}

fn valid_command(command: &str) -> Option<String> {
    let normalized = normalize_command(command);
    (!normalized.is_empty() && normalized.len() <= MAX_COMMAND_BYTES).then_some(normalized)
}

fn normalize_tool_id(value: Option<&str>) -> Option<String> {
    normalize(value).filter(|value| value.chars().count() <= 256)
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct CursorApprovalRememberResult {
    pub accepted: bool,
    pub inserted: bool,
    pub notification_correlation_key: Option<String>,
    pub expired_notification_correlation_keys: Vec<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct CursorApprovalClearResult {
    pub cleared: bool,
    pub notification_correlation_keys: Vec<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct CursorApprovalResolution {
    pub matched: bool,
    pub has_remaining: bool,
    pub expired: bool,
    pub remaining_display_command: Option<String>,
    pub notification_correlation_keys: Vec<String>,
    pub remaining_notification_correlation_key: Option<String>,
}

pub(super) fn has_unexpired_cursor_shell_approval(
    record: &ClaudeHookSessionRecord,
    timestamp: f64,
) -> bool {
    record.pending_cursor_shell_approvals.as_ref().is_some_and(|pending| {
        pending.iter().any(|approval| timestamp - approval.created_at <= MAX_APPROVAL_AGE)
    })
}

fn recent_fences(record: &ClaudeHookSessionRecord, timestamp: f64) -> HashMap<String, f64> {
    record.recently_cleared_cursor_shell_command_fingerprints
        .as_ref()
        .into_iter()
        .flat_map(|entries| entries.iter())
        .filter(|(_, cleared_at)| timestamp - **cleared_at <= MAX_CLEARED_AGE)
        .map(|(fingerprint, cleared_at)| (fingerprint.clone(), *cleared_at))
        .collect()
}

fn cap_fences(record: &mut ClaudeHookSessionRecord, fences: &mut HashMap<String, f64>) {
    if fences.len() <= MAX_CLEARED_FINGERPRINTS {
        return;
    }
    // Once evidence is discarded, command-only matching stays disabled even
    // after the retained fences expire. Stable tool IDs remain safe to match.
    record.cursor_shell_command_only_correlation_disabled = Some(true);
    let mut newest = fences.drain().collect::<Vec<_>>();
    newest.sort_by(|a, b| b.1.total_cmp(&a.1));
    newest.truncate(MAX_CLEARED_FINGERPRINTS);
    fences.extend(newest);
}

impl ClaudeHookSessionStore {
    pub fn remember_cursor_shell_approval(
        &self,
        session_id: &str,
        command: &str,
        tool_use_id: Option<String>,
    ) -> HookResult<CursorApprovalRememberResult> {
        self.remember_cursor_shell_approval_with_deadline(session_id, command, tool_use_id, None)
    }

    pub fn remember_cursor_shell_approval_with_deadline(
        &self,
        session_id: &str,
        command: &str,
        tool_use_id: Option<String>,
        deadline: Option<Instant>,
    ) -> HookResult<CursorApprovalRememberResult> {
        let (Some(session_id), Some(command)) = (normalize(Some(session_id)), valid_command(command)) else {
            return Ok(CursorApprovalRememberResult::default());
        };
        self.with_locked_state(deadline, true, |state| {
            let Some(mut record) = state.sessions.get(&session_id).cloned() else {
                return Ok(CursorApprovalRememberResult::default());
            };
            let timestamp = now();
            let had_unexpired = has_unexpired_cursor_shell_approval(&record, timestamp);
            let mut pending = record.pending_cursor_shell_approvals.clone().unwrap_or_default();
            let before_count = pending.len();
            let expired = pending.iter().filter(|approval| timestamp - approval.created_at > MAX_APPROVAL_AGE).cloned().collect::<Vec<_>>();
            let expired_keys = expired.iter().filter_map(|approval| approval.notification_correlation_key.clone()).collect::<Vec<_>>();
            let mut fences = recent_fences(&record, timestamp);
            for approval in &expired {
                fences.insert(approval.command_fingerprint.clone(), timestamp);
            }
            cap_fences(&mut record, &mut fences);
            pending.retain(|approval| timestamp - approval.created_at <= MAX_APPROVAL_AGE);
            let tool_id = normalize_tool_id(tool_use_id.as_deref());
            let (fingerprint, length) = PendingCursorShellApproval::identity(&command);
            let requires_tool_id = record.cursor_shell_command_only_correlation_disabled == Some(true)
                || fences.get(&fingerprint).is_some_and(|cleared_at| timestamp - *cleared_at <= MAX_CLEARED_AGE);
            let duplicate = tool_id.as_ref().and_then(|tool_id| pending.iter().position(|approval| approval.tool_use_id.as_ref() == Some(tool_id)));
            if let Some(index) = duplicate {
                let existing = &pending[index];
                let changed = existing.command_fingerprint != fingerprint || existing.command_length != length;
                if changed {
                    pending[index] = PendingCursorShellApproval::from_command_with_correlation(
                        &command, tool_id, existing.created_at, existing.requires_tool_use_id,
                        existing.notification_correlation_key.as_deref(),
                    );
                }
                let key = pending[index].notification_correlation_key.clone();
                let count_delta = if had_unexpired || pending.is_empty() { 0 } else { 1 };
                if !expired.is_empty() || pending.len() != before_count || changed {
                    record.recently_cleared_cursor_shell_command_fingerprints = Some(fences);
                    record.pending_cursor_shell_approvals = Some(pending);
                    record.updated_at = timestamp;
                    state.sessions.insert(session_id.clone(), record.clone());
                }
                state.add_cursor_pending_index(&session_id, &record.surface_id, count_delta);
                return Ok(CursorApprovalRememberResult {
                    accepted: true, inserted: false, notification_correlation_key: key,
                    expired_notification_correlation_keys: expired_keys,
                });
            }
            if pending.len() >= MAX_PENDING_APPROVALS {
                if !expired.is_empty() {
                    let is_empty = pending.is_empty();
                    record.recently_cleared_cursor_shell_command_fingerprints = Some(fences);
                    record.pending_cursor_shell_approvals = (!is_empty).then_some(pending);
                    record.updated_at = timestamp;
                    if is_empty {
                        state.remove_cursor_pending_index(&session_id, &record.surface_id, -1);
                    }
                    state.sessions.insert(session_id.clone(), record);
                }
                return Ok(CursorApprovalRememberResult {
                    expired_notification_correlation_keys: expired_keys,
                    ..Default::default()
                });
            }
            pending.push(PendingCursorShellApproval::from_command(&command, tool_id, timestamp, requires_tool_id));
            let key = pending.last().and_then(|approval| approval.notification_correlation_key.clone());
            record.recently_cleared_cursor_shell_command_fingerprints = Some(fences);
            record.pending_cursor_shell_approvals = Some(pending);
            record.updated_at = timestamp;
            state.add_cursor_pending_index(&session_id, &record.surface_id, if had_unexpired { 0 } else { 1 });
            state.sessions.insert(session_id.clone(), record);
            Ok(CursorApprovalRememberResult {
                accepted: true, inserted: true, notification_correlation_key: key,
                expired_notification_correlation_keys: expired_keys,
            })
        })
    }

    pub fn resolve_cursor_shell_approval(
        &self,
        session_id: &str,
        command: &str,
        update: &SessionUpdate,
        tool_use_id: Option<&str>,
        failure_was_error: bool,
        deadline: Option<Instant>,
    ) -> HookResult<CursorApprovalResolution> {
        let (Some(session_id), Some(command)) = (normalize(Some(session_id)), valid_command(command)) else {
            return Ok(CursorApprovalResolution::default());
        };
        self.with_locked_state(deadline, true, |state| {
            let Some(mut record) = state.sessions.get(&session_id).cloned() else {
                return Ok(CursorApprovalResolution::default());
            };
            let Some(mut pending) = record.pending_cursor_shell_approvals.clone() else {
                return Ok(CursorApprovalResolution::default());
            };
            let timestamp = now();
            let expired = pending.iter().filter(|approval| timestamp - approval.created_at > MAX_APPROVAL_AGE).cloned().collect::<Vec<_>>();
            let mut keys = expired.iter().filter_map(|approval| approval.notification_correlation_key.clone()).collect::<Vec<_>>();
            pending.retain(|approval| timestamp - approval.created_at <= MAX_APPROVAL_AGE);
            if !expired.is_empty() {
                let mut fences = recent_fences(&record, timestamp);
                for approval in &expired {
                    fences.insert(approval.command_fingerprint.clone(), timestamp);
                }
                cap_fences(&mut record, &mut fences);
                record.recently_cleared_cursor_shell_command_fingerprints = Some(fences);
            }
            let tool_id = normalize_tool_id(tool_use_id);
            let (fingerprint, length) = PendingCursorShellApproval::identity(&command);
            let matched_index = pending.iter().position(|approval| {
                if let (Some(tool_id), Some(pending_id)) = (tool_id.as_ref(), approval.tool_use_id.as_ref()) {
                    return tool_id == pending_id;
                }
                !approval.requires_tool_use_id
                    && approval.command_fingerprint == fingerprint
                    && approval.command_length == length
            });
            let Some(index) = matched_index else {
                if !expired.is_empty() {
                    record.pending_cursor_shell_approvals = (!pending.is_empty()).then(|| pending.clone());
                    if pending.is_empty() {
                        record.agent_lifecycle = Some("running".into());
                        record.runtime_status = Some("running".into());
                        record.last_notification_status = None;
                        record.last_subtitle = None;
                        record.last_body = None;
                        state.remove_cursor_pending_index(&session_id, &record.surface_id, -1);
                    } else {
                        state.add_cursor_pending_index(&session_id, &record.surface_id, 0);
                    }
                    state.sessions.insert(session_id.clone(), record);
                }
                return Ok(CursorApprovalResolution {
                    matched: false,
                    has_remaining: !pending.is_empty(),
                    expired: !expired.is_empty(),
                    remaining_display_command: pending.last().map(|approval| approval.display_command.clone()),
                    notification_correlation_keys: keys,
                    remaining_notification_correlation_key: pending.last().and_then(|approval| approval.notification_correlation_key.clone()),
                });
            };
            let matched = pending.remove(index);
            keys.extend(matched.notification_correlation_key);
            let has_remaining = !pending.is_empty();
            let previous_surface = record.surface_id.clone();
            update_record(&mut record, update, timestamp);
            record.agent_lifecycle = Some(if failure_was_error || has_remaining { "needs_input" } else { "running" }.into());
            record.runtime_status = Some(if failure_was_error { "error" } else if has_remaining { "needs_input" } else { "running" }.into());
            record.last_notification_status = if failure_was_error { Some("error".into()) } else if has_remaining { Some("needs_input".into()) } else { None };
            record.pending_cursor_shell_approvals = has_remaining.then(|| pending.clone());
            let surface_moved = previous_surface != record.surface_id;
            if surface_moved {
                state.remove_cursor_pending_index(&session_id, &previous_surface, -1);
            }
            if has_remaining {
                state.add_cursor_pending_index(&session_id, &record.surface_id, if surface_moved { 1 } else { 0 });
                record.last_body = pending.last().map(|approval| approval.display_command.clone());
            } else {
                if !surface_moved {
                    state.remove_cursor_pending_index(&session_id, &record.surface_id, -1);
                }
                record.last_subtitle = None;
                record.last_body = None;
            }
            state.sessions.insert(session_id.clone(), record);
            Ok(CursorApprovalResolution {
                matched: true,
                has_remaining,
                expired: !expired.is_empty(),
                remaining_display_command: pending.last().map(|approval| approval.display_command.clone()),
                notification_correlation_keys: keys,
                remaining_notification_correlation_key: pending.last().and_then(|approval| approval.notification_correlation_key.clone()),
            })
        })
    }

    pub fn clear_cursor_shell_approvals(&self, session_id: &str) -> HookResult<CursorApprovalClearResult> {
        self.clear_cursor_shell_approvals_with_deadline(session_id, None)
    }

    pub fn clear_cursor_shell_approvals_with_deadline(
        &self,
        session_id: &str,
        deadline: Option<Instant>,
    ) -> HookResult<CursorApprovalClearResult> {
        let Some(session_id) = normalize(Some(session_id)) else {
            return Ok(CursorApprovalClearResult::default());
        };
        self.with_locked_state(deadline, true, |state| {
            let Some(mut record) = state.sessions.get(&session_id).cloned() else {
                return Ok(CursorApprovalClearResult::default());
            };
            let pending = record.pending_cursor_shell_approvals.take().unwrap_or_default();
            if pending.is_empty() {
                return Ok(CursorApprovalClearResult::default());
            }
            let keys = pending.iter().filter_map(|approval| approval.notification_correlation_key.clone()).collect();
            let timestamp = now();
            let mut fences = recent_fences(&record, timestamp);
            for approval in pending {
                fences.insert(approval.command_fingerprint, timestamp);
            }
            cap_fences(&mut record, &mut fences);
            record.recently_cleared_cursor_shell_command_fingerprints = Some(fences);
            state.remove_cursor_pending_index(&session_id, &record.surface_id, -1);
            record.last_subtitle = None;
            record.last_body = None;
            record.last_notification_status = None;
            record.updated_at = timestamp;
            state.sessions.insert(session_id.clone(), record);
            Ok(CursorApprovalClearResult { cleared: true, notification_correlation_keys: keys })
        })
    }

    pub fn has_pending_cursor_shell_approval(
        &self,
        surface_id: &str,
        excluding_session_id: Option<&str>,
    ) -> HookResult<bool> {
        self.has_pending_cursor_shell_approval_with_deadline(surface_id, excluding_session_id, None)
    }

    pub fn has_pending_cursor_shell_approval_with_deadline(
        &self,
        surface_id: &str,
        excluding_session_id: Option<&str>,
        deadline: Option<Instant>,
    ) -> HookResult<bool> {
        // An explicitly empty exclusion remains an empty session identity,
        // matching Swift's map(normalizeSessionId), rather than becoming None.
        let excluded = excluding_session_id.map(str::trim);
        self.with_locked_state(deadline, false, |state| {
            let timestamp = now();
            let indexed = state.pending_cursor_approval_sessions_by_surface.get(surface_id).map(Vec::as_slice).unwrap_or_default();
            if indexed.iter().any(|candidate| {
                state.sessions.get(candidate).is_some_and(|record| {
                    has_unexpired_cursor_shell_approval(record, timestamp)
                        && record.surface_id == surface_id
                        && excluded != Some(candidate.as_str())
                })
            }) {
                return Ok(true);
            }
            let count = state.pending_cursor_approval_session_counts_by_surface.get(surface_id).copied().unwrap_or(indexed.len() as i64);
            let hidden_count = (count - indexed.len() as i64).max(0);
            Ok(hidden_count > 0
                && (state.pending_cursor_approval_surface_overflow.get(surface_id) == Some(&true) || count > 1))
        })
    }

    pub fn acquire_cursor_shell_approval_reconciliation_lock(
        &self,
        session_id: &str,
        surface_id: Option<&str>,
        deadline: Option<Instant>,
    ) -> HookResult<CursorShellApprovalReconciliationLease> {
        let session_id = normalize(Some(session_id)).ok_or_else(|| HookStateError::Invalid("Cursor approval reconciliation requires a session".into()))?;
        let identity = normalize(surface_id).unwrap_or(session_id);
        let digest = Sha256::digest(identity.as_bytes());
        let offset = u64::from_be_bytes(digest[..8].try_into().expect("SHA-256 prefix"));
        let lock_start = ((offset & 0x3FFF_FFFF_FFFF_FFFF) + 1) as libc::off_t;
        let path = PathBuf::from(format!("{}.cursor-approval-reconcile.lock", self.path.display()));
        if let Some(parent) = path.parent() {
            fs::DirBuilder::new().recursive(true).mode(0o700).create(parent)?;
        }
        let file = OpenOptions::new().create(true).read(true).write(true).mode(0o600).open(&path)?;
        let mut lock: libc::flock = unsafe { std::mem::zeroed() };
        lock.l_start = lock_start;
        lock.l_len = 1;
        lock.l_type = libc::F_WRLCK as _;
        lock.l_whence = libc::SEEK_SET as _;
        let deadline = deadline.unwrap_or_else(|| Instant::now() + Duration::from_secs(3));
        loop {
            if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETLK, &lock) } == 0 {
                return Ok(CursorShellApprovalReconciliationLease { file: Some(file), lock_start });
            }
            let error = io::Error::last_os_error();
            if !matches!(error.raw_os_error(), Some(libc::EACCES) | Some(libc::EAGAIN)) || Instant::now() >= deadline {
                return Err(HookStateError::Lock(format!("Failed to lock Cursor approval reconciliation: {}: {error}", path.display())));
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

/// One byte in a shared file orders state changes and socket reconciliation
/// across hook processes for the same globally stable surface identity.
pub struct CursorShellApprovalReconciliationLease {
    file: Option<File>,
    lock_start: libc::off_t,
}

impl CursorShellApprovalReconciliationLease {
    pub fn release(&mut self) {
        let Some(file) = self.file.take() else { return };
        let mut lock: libc::flock = unsafe { std::mem::zeroed() };
        lock.l_start = self.lock_start;
        lock.l_len = 1;
        lock.l_type = libc::F_UNLCK as _;
        lock.l_whence = libc::SEEK_SET as _;
        unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETLK, &lock); }
        // Dropping File closes the descriptor, including on repeated release.
    }
}

impl Drop for CursorShellApprovalReconciliationLease {
    fn drop(&mut self) { self.release(); }
}

impl ClaudeHookState {
    pub(super) fn prepare_cursor_pending_index(&mut self) {
        let legacy = self.pending_cursor_approval_sessions_by_surface.keys().any(|key| key.contains('|'));
        let missing_counts = !self.pending_cursor_approval_sessions_by_surface.is_empty()
            && self.pending_cursor_approval_session_counts_by_surface.is_empty();
        let missing_overflow = self.pending_cursor_approval_session_counts_by_surface.iter().any(|(key, count)| {
            *count > MAX_INDEX_ENTRIES as i64 && self.pending_cursor_approval_surface_overflow.get(key) != Some(&true)
        });
        if !self.pending_cursor_approval_index_initialized || legacy || missing_counts || missing_overflow {
            self.reconcile_pending_index();
            self.pending_cursor_approval_index_initialized = true;
        }
        self.prune_cursor_pending_index();
    }

    pub(super) fn reconcile_pending_index(&mut self) {
        let timestamp = now();
        let mut index: HashMap<String, Vec<String>> = HashMap::new();
        let mut counts: HashMap<String, i64> = HashMap::new();
        for (session_id, record) in &self.sessions {
            if !has_unexpired_cursor_shell_approval(record, timestamp) { continue; }
            *counts.entry(record.surface_id.clone()).or_default() += 1;
            let ids = index.entry(record.surface_id.clone()).or_default();
            ids.push(session_id.clone());
            if ids.len() > MAX_INDEX_ENTRIES {
                ids.drain(..ids.len() - MAX_INDEX_ENTRIES);
            }
        }
        self.pending_cursor_approval_sessions_by_surface = index;
        self.pending_cursor_approval_surface_overflow = counts.iter().filter(|(_, count)| **count > MAX_INDEX_ENTRIES as i64).map(|(key, _)| (key.clone(), true)).collect();
        self.pending_cursor_approval_session_counts_by_surface = counts;
    }

    pub(super) fn prune_cursor_pending_index(&mut self) {
        let timestamp = now();
        let mut next = HashMap::new();
        let mut counts = self.pending_cursor_approval_session_counts_by_surface.clone();
        for (key, ids) in &self.pending_cursor_approval_sessions_by_surface {
            let valid = ids.iter().filter(|session_id| {
                self.sessions.get(*session_id).is_some_and(|record| {
                    record.surface_id == *key && has_unexpired_cursor_shell_approval(record, timestamp)
                })
            }).cloned().collect::<Vec<_>>();
            let current_count = counts.get(key).copied().unwrap_or(ids.len() as i64);
            let removed_known = (ids.len() - valid.len()) as i64;
            let remaining_count = (current_count - removed_known).max(0);
            if remaining_count > 0 {
                counts.insert(key.clone(), remaining_count);
            } else {
                counts.remove(key);
            }
            if !valid.is_empty() {
                let start = valid.len().saturating_sub(MAX_INDEX_ENTRIES);
                next.insert(key.clone(), valid[start..].to_vec());
            }
        }
        counts.retain(|key, count| {
            *count > 0 && (next.contains_key(key) || *count > MAX_INDEX_ENTRIES as i64 || self.pending_cursor_approval_surface_overflow.get(key) == Some(&true))
        });
        self.pending_cursor_approval_surface_overflow.retain(|key, _| counts.contains_key(key));
        self.pending_cursor_approval_sessions_by_surface = next;
        self.pending_cursor_approval_session_counts_by_surface = counts;
    }

    pub(super) fn add_cursor_pending_index(&mut self, session_id: &str, surface_id: &str, count_delta: i64) {
        let mut ids = self.pending_cursor_approval_sessions_by_surface.get(surface_id).cloned().unwrap_or_default();
        if !ids.iter().any(|id| id == session_id) {
            ids.push(session_id.to_string());
            if ids.len() > MAX_INDEX_ENTRIES {
                ids.drain(..ids.len() - MAX_INDEX_ENTRIES);
            }
            self.pending_cursor_approval_sessions_by_surface.insert(surface_id.to_string(), ids.clone());
        }
        if count_delta != 0 {
            let current = self.pending_cursor_approval_session_counts_by_surface.get(surface_id).copied()
                .unwrap_or((ids.len() as i64 - i64::from(count_delta > 0)).max(0));
            let next = (current + count_delta).max(0);
            self.pending_cursor_approval_session_counts_by_surface.insert(surface_id.to_string(), next);
            if next > MAX_INDEX_ENTRIES as i64 {
                self.pending_cursor_approval_surface_overflow.insert(surface_id.to_string(), true);
            }
        } else {
            self.pending_cursor_approval_session_counts_by_surface.entry(surface_id.to_string()).or_insert(ids.len() as i64);
        }
        self.pending_cursor_approval_index_initialized = true;
    }

    pub(super) fn remove_cursor_pending_index(&mut self, session_id: &str, surface_id: &str, count_delta: i64) {
        let mut ids = self.pending_cursor_approval_sessions_by_surface.get(surface_id).cloned().unwrap_or_default();
        ids.retain(|id| id != session_id);
        let current = self.pending_cursor_approval_session_counts_by_surface.get(surface_id).copied().unwrap_or(ids.len() as i64);
        let next = (current + count_delta).max(0);
        if next == 0 {
            self.pending_cursor_approval_sessions_by_surface.remove(surface_id);
            self.pending_cursor_approval_session_counts_by_surface.remove(surface_id);
            self.pending_cursor_approval_surface_overflow.remove(surface_id);
        } else {
            self.pending_cursor_approval_sessions_by_surface.insert(surface_id.to_string(), ids);
            self.pending_cursor_approval_session_counts_by_surface.insert(surface_id.to_string(), next);
            if next > MAX_INDEX_ENTRIES as i64 {
                self.pending_cursor_approval_surface_overflow.insert(surface_id.to_string(), true);
            }
        }
        self.pending_cursor_approval_index_initialized = true;
    }

    pub(super) fn reconcile_cursor_pending_index_after_update(
        &mut self,
        session_id: &str,
        previous_surface_id: Option<&str>,
        previous_had_pending: bool,
        record: &ClaudeHookSessionRecord,
        timestamp: f64,
    ) {
        let moved = previous_surface_id != Some(record.surface_id.as_str());
        if let Some(surface_id) = previous_surface_id.filter(|_| moved) {
            self.remove_cursor_pending_index(session_id, surface_id, -1);
        }
        if has_unexpired_cursor_shell_approval(record, timestamp) {
            self.add_cursor_pending_index(session_id, &record.surface_id, if moved || !previous_had_pending { 1 } else { 0 });
        } else if previous_had_pending {
            self.remove_cursor_pending_index(session_id, &record.surface_id, -1);
        }
    }
}
