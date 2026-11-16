//! Paired text projections used by the summary bound and the book codec.

use crate::Summary;
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TextRef<'a> {
    title: &'a str,
    harness: &'a str,
    state: &'a str,
    last_activity: u64,
    unread: u32,
    workspace: &'a Option<String>,
    pinned: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    archived: bool,
    peer_form: &'a Option<Box<RawValue>>,
    extra: &'a RawValue,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Text {
    pub title: String,
    pub harness: String,
    pub state: String,
    pub last_activity: u64,
    pub unread: u32,
    pub workspace: Option<String>,
    pub pinned: bool,
    #[serde(default)]
    pub archived: bool,
    pub peer_form: Option<Box<RawValue>>,
    pub extra: Box<RawValue>,
}

pub fn text(summary: &Summary) -> TextRef<'_> {
    TextRef {
        title: &summary.title,
        harness: &summary.harness,
        state: &summary.state,
        last_activity: summary.last_activity,
        unread: summary.unread,
        workspace: &summary.workspace,
        pinned: summary.pinned,
        archived: summary.archived,
        peer_form: &summary.peer_form,
        extra: &summary.extra,
    }
}

pub(super) fn text_len(summary: &Summary) -> usize {
    serde_json::to_vec(&text(summary)).map_or(usize::MAX, |bytes| bytes.len())
}
