use super::*;

impl Config {
    /// Set a host-wide session resource setting from the CLI. `default`,
    /// `none`, and `clear` remove an override and restore the computed default.
    /// `acpmux config --set KEY=VALUE`: a permission-mode key
    /// (`set_permission_mode`), `remote_daemon` (a loopback `host:port`, or `none`),
    /// `lane_gh_broker` (the broker's socket path, or `none`), `transport.wireguard` (`true`/`false`), else a
    /// session resource limit (`set_session_resource`).
    ///
    /// The whole resulting config must pass the daemon's start check
    /// ([`Self::start_refusal`], `config/start_check.rs`): otherwise nothing changes and the
    /// refusal says why, so `config --set` never writes a config the daemon refuses to start with.
    pub fn set(&mut self, key: &str, value: &str) -> Result<()> {
        let before = self.clone();
        self.apply_setting(key, value)?;
        if let Err(refused) = self.start_refusal() {
            *self = before;
            return Err(refused.context(format!(
                "not set: the acpmux daemon would refuse to start with {key}={value}"
            )));
        }
        Ok(())
    }

    /// [`Self::set`]'s change alone, unchecked.
    fn apply_setting(&mut self, key: &str, value: &str) -> Result<()> {
        if self.set_permission_mode(key, value)? {
            return Ok(());
        }
        if matches!(
            key.trim().replace('-', "_").to_ascii_lowercase().as_str(),
            "remote_daemon" | "remotedaemon"
        ) {
            let value = value.trim();
            self.remote_daemon = match value.to_ascii_lowercase().as_str() {
                "" | "none" | "clear" | "off" => None,
                _ => Some(loopback_daemon_address(value)?.to_string()),
            };
            return Ok(());
        }
        if matches!(
            key.trim().replace('-', "_").to_ascii_lowercase().as_str(),
            "lane_gh_broker" | "laneghbroker"
        ) {
            let value = value.trim();
            self.lane_gh_broker = match value.to_ascii_lowercase().as_str() {
                "" | "none" | "clear" | "off" => None,
                _ if value.starts_with('/') || value.starts_with("~/") => Some(value.to_owned()),
                _ => anyhow::bail!(
                    "lane_gh_broker must be the broker's socket as an absolute path (or ~/...)"
                ),
            };
            return Ok(());
        }
        if matches!(
            key.trim().replace('-', "_").to_ascii_lowercase().as_str(),
            "direct_port" | "directport"
        ) {
            self.direct_port = match value.trim().to_ascii_lowercase().as_str() {
                "" | "none" | "clear" | "off" => None,
                port => Some(port.parse::<u16>().ok().filter(|p| *p != 0).ok_or_else(|| {
                    anyhow::anyhow!("direct_port must be a TCP port (1-65535) or none")
                })?),
            };
            return Ok(());
        }
        // The Labs WireGuard transport. It needs `wireguardStatic` (the start check refuses it
        // without); the hub carrier does not need it (`hub_carrier.rs`: the node key alone).
        if matches!(key.trim().to_ascii_lowercase().as_str(), "transport.wireguard") {
            self.transport.wireguard = match value.trim().to_ascii_lowercase().as_str() {
                "true" | "on" | "1" => true,
                "false" | "off" | "0" => false,
                _ => anyhow::bail!("transport.wireguard must be true or false"),
            };
            return Ok(());
        }
        self.set_session_resource(key, value)
    }

    /// The permission mode new chats start in: `permissions.default` (also
    /// `defaultPermissionMode`) for every harness, `permissions.HARNESS` (also
    /// `defaults.HARNESS.permissionMode`) for one family or profile. Values:
    /// `yolo` / `fullAccess`, `standard`, `ask`, or `default` to clear.
    /// `Ok(false)`: not a permission key.
    pub fn set_permission_mode(&mut self, key: &str, value: &str) -> Result<bool> {
        let key = key.trim();
        let harness = if matches!(
            key,
            "permissions.default" | "defaultPermissionMode" | "default_permission_mode"
        ) {
            None
        } else if let Some(h) = key.strip_prefix("permissions.") {
            Some(h)
        } else if let Some(h) = key.strip_prefix("defaults.").and_then(|r| {
            r.strip_suffix(".permissionMode").or_else(|| r.strip_suffix(".permission_mode"))
        }) {
            Some(h)
        } else {
            return Ok(false);
        };
        if harness.is_some_and(|h| h.is_empty() || h.contains('.')) {
            anyhow::bail!("{key}: name one harness, for example permissions.codex");
        }
        let mode = match value.trim() {
            "" | "default" | "none" | "clear" => None,
            v => Some(normalize_permission_mode(v).ok_or_else(|| {
                anyhow::anyhow!("{key} must be yolo (fullAccess), standard, ask or default")
            })?),
        };
        match harness {
            None => self.default_permission_mode = mode.map(str::to_owned),
            Some(h) => {
                let entry = self.defaults.entry(h.to_owned()).or_default();
                entry.permission_mode = mode.map(str::to_owned);
                if entry.is_empty() {
                    self.defaults.remove(h);
                }
            }
        }
        Ok(true)
    }

    pub fn set_session_resource(&mut self, key: &str, value: &str) -> Result<()> {
        let key = key.trim().replace('-', "_").to_ascii_lowercase();
        if matches!(
            key.as_str(),
            "session.cpu_class" | "session.cpuclass" | "cpu_class" | "cpuclass"
        ) {
            let value = value.trim();
            self.session.cpu_class = match value.to_ascii_lowercase().as_str() {
                "" | "default" | "none" | "clear" => None,
                _ => Some(crate::cpu_class::CpuClass::parse(value).ok_or_else(|| {
                    anyhow::anyhow!("{key} must be `dynamic`, `background`, `normal` or `default`")
                })?),
            };
            return Ok(());
        }
        let slot = match key.as_str() {
            "session.memory_mb" | "session.memorymb" | "memory_mb" | "memorymb" => {
                &mut self.session.memory_mb
            }
            "session.swap_mb" | "session.swapmb" | "swap_mb" | "swapmb" => {
                &mut self.session.swap_mb
            }
            "session.tasks_max" | "session.tasksmax" | "tasks_max" | "tasksmax" => {
                &mut self.session.tasks_max
            }
            "session.sessions_tasks_max"
            | "session.sessionstasksmax"
            | "sessions_tasks_max"
            | "sessionstasksmax" => &mut self.session.sessions_tasks_max,
            "session.lanes" | "lanes" => &mut self.session.lanes,
            "session.disk_mb" | "session.diskmb" | "disk_mb" | "diskmb" => {
                &mut self.session.disk_mb
            }
            _ => anyhow::bail!(
                "unknown session resource setting `{key}` (use session.memory_mb, \
                 session.swap_mb, session.tasks_max, session.sessions_tasks_max, \
                 session.lanes, session.disk_mb or session.cpu_class)"
            ),
        };
        let tasks = key.contains("tasks") || key.contains("lanes");
        let value = value.trim();
        *slot = match value.to_ascii_lowercase().as_str() {
            "" | "default" | "none" | "clear" => None,
            // A task cap of 0 is no cap; `infinity` says the same.
            "infinity" if tasks => Some(0),
            _ => Some(value.parse::<u64>().with_context(|| {
                if tasks {
                    format!("{key} must be a non-negative integer count, `infinity` or `default`")
                } else {
                    format!("{key} must be a non-negative integer MiB or `default`")
                }
            })?),
        };
        Ok(())
    }

    /// `agentInbox`, or its default: on.
    pub fn agent_inbox(&self) -> bool {
        self.agent_inbox.unwrap_or(true)
    }

    /// `agentStartTimeoutMs`, or its 90 s default.
    pub fn agent_start_timeout(&self) -> std::time::Duration {
        std::time::Duration::from_millis(self.agent_start_timeout_ms.unwrap_or(90_000))
    }

    /// `uploadsMaxAgeDays`, or its 30-day default; None when it is 0 (keep them).
    pub fn uploads_max_age(&self) -> Option<std::time::Duration> {
        match self.uploads_max_age_days.unwrap_or(30) {
            0 => None,
            days => Some(std::time::Duration::from_secs(days.saturating_mul(24 * 60 * 60))),
        }
    }

    /// `silentTurnMs`, or its 90 s default; None when it is 0 (off).
    pub fn silent_turn(&self) -> Option<std::time::Duration> {
        match self.silent_turn_ms.unwrap_or(90_000) {
            0 => None,
            ms => Some(std::time::Duration::from_millis(ms)),
        }
    }

    /// `stalledTurnMs`, or its 10 minute default; None when it is 0 (off).
    pub fn stalled_turn(&self) -> Option<u64> {
        match self.stalled_turn_ms.unwrap_or(600_000) {
            0 => None,
            ms => Some(ms),
        }
    }

    /// `stalledTurnEndMs`, or its 6 h default; None when it is 0 (off).
    pub fn stalled_turn_end(&self) -> Option<std::time::Duration> {
        match self.stalled_turn_end_ms.unwrap_or(6 * 60 * 60 * 1000) {
            0 => None,
            ms => Some(std::time::Duration::from_millis(ms)),
        }
    }

    /// Family of a configured profile.
    pub fn family(&self, profile: &str) -> Option<String> {
        self.harnesses.get(profile).map(|p| derive_family(profile, p))
    }

    /// Families with their profiles, in name order.
    pub fn families(&self) -> BTreeMap<String, Vec<String>> {
        let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for (name, p) in &self.harnesses {
            out.entry(derive_family(name, p)).or_default().push(name.clone());
        }
        out
    }

    /// The profile for a `-m` head: a family (its `prefer` list, else its
    /// only profile, else the profile named like it), else a profile name.
    /// Anything else, or a family with several profiles and no `prefer`,
    /// is an error that names what exists.
    pub fn resolve_harness(&self, head: &str) -> std::result::Result<String, String> {
        let fams = self.families();
        if let Some(members) = fams.get(head) {
            if let Some(d) = self.defaults.get(head) {
                // An unavailable profile is skipped; the next preference serves.
                // Only the family's own profiles count; a stray name never
                // routes the family to another family's profile.
                if let Some(p) = d.prefer.iter().find(|p| {
                    members.contains(*p)
                        && self.harnesses.contains_key(*p)
                        && !self.unavailable.contains_key(*p)
                }) {
                    return Ok(p.clone());
                }
            }
            if members.len() == 1 {
                return Ok(members[0].clone());
            }
            if members.iter().any(|m| m == head) {
                return Ok(head.to_owned());
            }
            return Err(format!(
                "family {head:?} has several profiles ({}) and no preference; write one of them, or `acpmux defaults {head} prefer=…`",
                members.join(", ")
            ));
        }
        if self.harnesses.contains_key(head) {
            return Ok(head.to_owned());
        }
        Err(format!(
            "unknown harness {head:?}; families: {}; profiles: {}; presets: {}",
            fams.keys().cloned().collect::<Vec<_>>().join(", "),
            self.harnesses.keys().cloned().collect::<Vec<_>>().join(", "),
            if self.presets.is_empty() {
                "none".to_owned()
            } else {
                self.presets.keys().cloned().collect::<Vec<_>>().join(", ")
            }
        ))
    }

    /// Defaults that apply to a profile: the family's entry, then the
    /// `defaults` entry named after the profile, then the profile's own
    /// inline `model`/`effort`/`policy`.
    pub fn defaults_for(&self, profile: &str) -> SessionDefaults {
        let mut d = SessionDefaults::default();
        if let Some(f) = self.family(profile) {
            if let Some(fd) = self.defaults.get(&f) {
                d.overlay(fd);
            }
            if f != profile
                && let Some(pd) = self.defaults.get(profile)
            {
                d.overlay(pd);
            }
        }
        if let Some(p) = self.harnesses.get(profile) {
            d.overlay(&SessionDefaults {
                model: p.model.clone(),
                effort: p.effort.clone(),
                policy: p.policy,
                ..Default::default()
            });
        }
        d
    }

    pub fn path() -> PathBuf {
        home().join("config.json")
    }

    /// Load config. When no file exists, build defaults and try to import
    /// agent profiles from `~/.acpx/config.json` so existing setups keep working.
    pub fn load() -> Result<Self> {
        Self::load_from(&Self::path())
    }

    pub fn load_from(path: &Path) -> Result<Self> {
        Self::load_from_with(path, &ProfileSources::current())
    }

    /// `load_from` with explicit profile file sources.
    pub fn load_from_with(path: &Path, sources: &ProfileSources) -> Result<Self> {
        let path = path.to_owned();
        let mut cfg = match std::fs::symlink_metadata(&path) {
            Ok(_) => {
                let mut text = String::new();
                private_state_file(&path)?
                    .read_to_string(&mut text)
                    .with_context(|| format!("read {}", path.display()))?;
                serde_json::from_str::<Config>(&text)
                    .with_context(|| format!("parse {}", path.display()))?
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Config { file_missing: true, ..Config::default() }
            }
            Err(error) => return Err(error.into()),
        };
        cfg.join_profiles(profiles::load(sources));
        // A capture fixture (`harness_fixture.rs`) stands in for PATH,
        // `~/.acpx` and the ACP Registry: nothing of this host's joins.
        if let Some(fixture) = crate::harness_fixture::active() {
            cfg.join_fixture(fixture);
        } else {
            let route = coderouter_claude_route(cfg.coderouter_claude_route.as_deref());
            cfg.join_discovered(discover_harnesses(route.as_deref()));
            cfg.pick_auto_default();
        }
        // Installed ACP Registry agents (the cached copy; no network, nothing
        // started), after the default so a registry agent never becomes it
        // while a built-in harness exists.
        if crate::harness_fixture::active().is_none()
            && let Some(registry) = crate::registry::load_cached(&home())
        {
            let found = crate::registry::discovered(
                &registry,
                crate::registry::platform(),
                &which,
                &|id| cfg.harnesses.contains_key(id),
            );
            // Never the default: a registry agent runs only when picked.
            cfg.join_discovered(found);
        }
        cfg.folder_gate = path.parent().and_then(folder_profiles::FolderGate::for_home);
        cfg.profile_sources = sources.clone();
        cfg.cloud_host = crate::cloud_host::is_cloud_vm();
        cfg.path = Some(path);
        let read = (!cfg.file_missing).then(|| cfg.on_disk_value().ok()).flatten();
        cfg.saved = save_merge::SavedBase::new(read);
        Ok(cfg)
    }

    /// Without a configured default, prefer Claude, then Codex, then another coding ACP harness.
    /// Terminal, Chief and UniiChat harnesses are chosen only explicitly.
    fn pick_auto_default(&mut self) {
        if self.default_harness.is_none() {
            self.auto_default = true;
            self.default_harness = crate::default_harness::auto_default_harness(&self.harnesses);
        }
    }

    #[cfg(test)]
    pub(crate) fn pick_auto_default_for_tests(&mut self) {
        self.pick_auto_default();
    }

    /// A capture fixture's harnesses join as discovered ones would
    /// (`harness_fixture.rs`); configured entries still win.
    pub fn join_fixture(&mut self, fixture: &crate::harness_fixture::Fixture) {
        self.join_discovered(fixture.harnesses.clone());
        self.pick_auto_default();
    }

    /// Adds the profiles from profile files and cmux.json. They win over
    /// config.json entries with the same id (kept for `save`).
    pub fn join_profiles(&mut self, loaded: LoadedProfiles) {
        for (id, (profile, meta)) in loaded.profiles {
            if let Some(old) = self.harnesses.insert(id.clone(), profile)
                && !self.profile_meta.contains_key(&id)
            {
                self.shadowed_config.insert(id.clone(), old);
            }
            self.profile_meta.insert(id, meta);
        }
        self.profile_diagnostics.extend(loaded.diagnostics);
    }

    /// Joins discovered harnesses to the configured ones (configured entries
    /// always win) and sets the automatic Claude fallbacks and preference.
    pub fn join_discovered(&mut self, discovered: BTreeMap<String, HarnessProfile>) {
        let cfg = self;
        // Harnesses found on PATH join the configured ones, so installing an
        // adapter such as pi-acp is enough; configured entries always win.
        for (name, profile) in discovered {
            if !cfg.harnesses.contains_key(&name) {
                cfg.discovered.insert(name.clone());
                cfg.harnesses.insert(name, profile);
            }
        }
        // A configured CodeRouter route (`claude-cr`) is the first `claude`
        // preference and the direct login's fallback. The subrouter pool
        // (`claude-sr`) stays a profile a user names; discovery never
        // prefers it or falls back onto it.
        let route = CODEROUTER_CLAUDE_PROFILE;
        if cfg.discovered.contains(route) {
            if let Some(c) = cfg.harnesses.get_mut("claude")
                && c.fallback.is_none()
                && c.kind == HarnessKind::ClaudeStdio
            {
                c.fallback = Some(route.into());
                cfg.auto_fallback = Some(("claude".into(), route.into()));
            }
            // The route falls back to, and `-m claude` prefers, a direct
            // login only on acpmux's own adapter, never an ACP `claude`.
            let has_direct =
                cfg.harnesses.get("claude").is_some_and(|c| c.kind == HarnessKind::ClaudeStdio);
            if let Some(p) = cfg.harnesses.get_mut(route)
                && p.fallback.is_none()
                && has_direct
            {
                p.fallback = Some("claude".into());
            }
            let entry = cfg.defaults.entry("claude".into()).or_default();
            if entry.prefer.is_empty() {
                entry.prefer = [route, "claude"]
                    .iter()
                    .filter(|n| has_direct || **n != "claude")
                    .map(|n| n.to_string())
                    .collect();
                cfg.auto_prefer = Some(entry.prefer.clone());
            }
        }
        // Without a CodeRouter route, Claude falls back to the cmux router on DeepSeek V4 Flash
        // (its profile default). The free tier serves it to a signed-out attested Mac, and a
        // signed-in account pays under its plan (paid-plan.md §2). Only when no route took the slot.
        let claude_has_no_fallback = cfg
            .harnesses
            .get("claude")
            .is_some_and(|c| c.kind == HarnessKind::ClaudeStdio && c.fallback.is_none());
        if cfg.discovered.contains(discover::CMUX_ROUTER_PROFILE)
            && claude_has_no_fallback
            && let Some(c) = cfg.harnesses.get_mut("claude")
        {
            c.fallback = Some(discover::CMUX_ROUTER_PROFILE.into());
            cfg.auto_fallback = Some(("claude".into(), discover::CMUX_ROUTER_PROFILE.into()));
        }
    }

    /// Where preset directories live (`presets/` next to config.json); None
    /// for an in-code config, which then takes no `systemPrompt`.
    pub fn presets_dir(&self) -> Option<PathBuf> {
        self.path.as_ref().and_then(|p| p.parent()).map(|d| d.join("presets"))
    }

    /// Write back to the file this config came from. No-op for in-code configs.
    pub fn save(&self) -> Result<()> {
        self.save_with_writer(write_atomic)
    }

    /// Preserve discovered/shadowed profile filtering when a caller needs a
    /// stronger durability contract than ordinary config writes.
    pub(crate) fn save_with_writer(
        &self,
        write: impl FnOnce(&Path, &[u8]) -> Result<()>,
    ) -> Result<()> {
        let Some(path) = &self.path else {
            tracing::debug!("config has no file; not saved");
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            private_state_dir(parent)?;
        }
        save_merge::save_merged(path, &self.saved, self.on_disk_value()?, write)
    }

    /// The config as a save writes it: without what discovery, profile files and this run
    /// added, with the config.json entries profile files replaced.
    fn on_disk_value(&self) -> Result<serde_json::Value> {
        let mut on_disk = self.clone();
        on_disk
            .harnesses
            .retain(|n, _| !self.discovered.contains(n) && !self.profile_meta.contains_key(n));
        for (n, p) in &self.shadowed_config {
            on_disk.harnesses.insert(n.clone(), p.clone());
        }
        if let Some((p, f)) = &self.auto_fallback
            && let Some(prof) = on_disk.harnesses.get_mut(p)
            && prof.fallback.as_deref() == Some(f.as_str())
        {
            prof.fallback = None;
        }
        if self.auto_default {
            on_disk.default_harness = None;
        }
        if let Some(generated) = &self.auto_prefer
            && let Some(d) = on_disk.defaults.get_mut("claude")
            && d.prefer == *generated
        {
            d.prefer.clear();
            if d.is_empty() {
                on_disk.defaults.remove("claude");
            }
        }
        Ok(serde_json::to_value(&on_disk)?)
    }

    pub fn profile(&self, name: &str) -> Option<&HarnessProfile> {
        self.harnesses.get(name)
    }

    /// The web listener this daemon actually serves, if any.
    pub fn web_listener(&self) -> Option<&WebSocketConfig> {
        self.websocket.as_ref().filter(|_| !self.web_unbound)
    }
}
