//! `window_record.list`, `window_record.put`, and `window_record.delete` on a
//! session handle (capability `window-records-v1`): one personal record per
//! app window, owned by the install that hosts the window, with its own
//! revision for compare-and-swap. A daemon without the capability refuses
//! these operations with a protocol error.

use super::super::*;
use crate::resource::model::deserialize_decimal;
use serde::Deserialize;

/// Largest serialized record `window_record.put` accepts.
pub const WINDOW_RECORD_MAX_BYTES: usize = 64 * 1024;

/// One window record.
#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct WindowRecordSnapshot {
    /// `<install_id>/<window_id>`; the id of the record's state changes.
    pub id: String,
    pub install_id: String,
    pub window_id: String,
    /// The install that hosts the window and is the record's only writer.
    pub owner: String,
    /// The record's own revision; every put advances it.
    #[serde(deserialize_with = "deserialize_decimal")]
    pub revision: u64,
    /// The app's window state; always a JSON object.
    pub record: Document,
    #[serde(deserialize_with = "deserialize_decimal")]
    pub updated_at_ms: u64,
}

/// The record `window_record.delete` removed.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct WindowRecordDeleteResult {
    pub id: String,
    /// The revision the record had when it was deleted.
    #[serde(deserialize_with = "deserialize_decimal")]
    pub revision: u64,
}

impl Session {
    /// Every window record of the session.
    pub fn window_records(&self) -> Result<Vec<WindowRecordSnapshot>> {
        let rows = self.client.read(ops::WINDOW_RECORD_LIST, self.params())?;
        wire::decode_exact(&rows, "window records")
    }

    /// Replaces the record of `window_id` owned by `install_id` with a fresh
    /// idempotency key. `expected_revision` is the record's own revision
    /// (`Some(0)`: the record must not exist; `None`: no precondition); a
    /// mismatch is `revision.conflict` and writes nothing.
    pub fn put_window_record(
        &self,
        install_id: impl Into<String>,
        window_id: impl Into<String>,
        record: Value,
        expected_revision: Option<u64>,
    ) -> Result<MutationResult<WindowRecordSnapshot>> {
        let mutation = MutationOptions::unique()?;
        self.put_window_record_with(install_id, window_id, record, expected_revision, mutation)
    }

    /// As [`Session::put_window_record`] with caller mutation options. The
    /// record revision is `expected_revision`, so `mutation` must not carry
    /// one.
    pub fn put_window_record_with(
        &self,
        install_id: impl Into<String>,
        window_id: impl Into<String>,
        record: Value,
        expected_revision: Option<u64>,
        mutation: MutationOptions,
    ) -> Result<MutationResult<WindowRecordSnapshot>> {
        if !record.is_object() {
            return Err(Error::InvalidArgument("window record must be a JSON object".to_string()));
        }
        let size = serde_json::to_vec(&record).map_err(|e| Error::Decode(e.to_string()))?.len();
        if size > WINDOW_RECORD_MAX_BYTES {
            return Err(Error::InvalidArgument(format!(
                "window record has {size} bytes; the limit is {WINDOW_RECORD_MAX_BYTES}"
            )));
        }
        let params = self.window_params(install_id, window_id, expected_revision, &mutation)?;
        mutation_snapshot(
            self.client.mutate(ops::WINDOW_RECORD_PUT, params.value("record", record), mutation)?,
            "window record",
        )
    }

    /// Deletes the record of `window_id` owned by `install_id` with a fresh
    /// idempotency key; `expected_revision` as in `put_window_record`.
    pub fn delete_window_record(
        &self,
        install_id: impl Into<String>,
        window_id: impl Into<String>,
        expected_revision: Option<u64>,
    ) -> Result<MutationResult<WindowRecordDeleteResult>> {
        let mutation = MutationOptions::unique()?;
        self.delete_window_record_with(install_id, window_id, expected_revision, mutation)
    }

    pub fn delete_window_record_with(
        &self,
        install_id: impl Into<String>,
        window_id: impl Into<String>,
        expected_revision: Option<u64>,
        mutation: MutationOptions,
    ) -> Result<MutationResult<WindowRecordDeleteResult>> {
        let params = self.window_params(install_id, window_id, expected_revision, &mutation)?;
        mutation_snapshot(
            self.client.mutate(ops::WINDOW_RECORD_DELETE, params, mutation)?,
            "window record delete result",
        )
    }

    fn window_params(
        &self,
        install_id: impl Into<String>,
        window_id: impl Into<String>,
        expected_revision: Option<u64>,
        mutation: &MutationOptions,
    ) -> Result<Params> {
        if mutation.expected_revision.is_some() {
            return Err(Error::InvalidArgument(
                "a window record takes its own revision as expected_revision, not a cursor \
                 revision in MutationOptions"
                    .to_string(),
            ));
        }
        let (install_id, window_id) = (install_id.into(), window_id.into());
        validate_record_key("install id", &install_id)?;
        validate_record_key("window id", &window_id)?;
        let params = self.params().string("install_id", install_id).string("window_id", window_id);
        Ok(params.optional_u64(field::EXPECTED_REVISION, expected_revision))
    }
}

/// 1 to 128 ASCII letters, digits, `-`, `_`, `.`, or `:`.
fn validate_record_key(label: &str, value: &str) -> Result<()> {
    let valid = (1..=128).contains(&value.len())
        && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_.:".contains(&byte));
    if !valid {
        return Err(Error::InvalidArgument(format!(
            "window record {label} must be 1 to 128 ASCII letters, digits, '-', '_', '.', or ':'"
        )));
    }
    Ok(())
}
