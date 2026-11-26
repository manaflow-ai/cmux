//! The list of the person's Auto chats, and what the phone says about where each one is.

use cmux_auto_session::cloud::{AutoCloud, CloudResult};
use cmux_auto_session::wire::{Blocked, Delivery, Repo, SessionView, State};
use serde::Serialize;

/// How many chats one request asks for (the store's most).
pub const PAGE: u32 = 100;

/// The list stops after this many pages and says there are more.
pub const MAX_PAGES: usize = 20;

/// How many recent repositories a new chat offers.
pub const RECENT_REPOS: usize = 20;

/// Where a chat is, as the phone says it. The words are the app's; this is which of them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Place {
    /// A Cloud machine runs it: "Running in the Cloud".
    Cloud,
    /// A Cloud machine is being started for it: "Resuming…".
    Resuming,
    /// A Cloud machine runs it and it goes home when this turn ends.
    ComingBack,
    /// A Mac runs it.
    OnMac,
    /// Nobody runs it and nothing waits. The phone says nothing.
    Idle,
    /// It has work and the person has no Cloud machine for it: "Auto needs a Cloud machine."
    NoMachine,
}

/// What the phone says about `view`. `waiting`: what the store answered to a message from this
/// phone that the chat's holder has not taken yet. What stops Auto comes first, because it is
/// the one state the person can change. A message a machine is being started for says
/// resuming whatever the chat's state. A chat nobody runs says nothing until a message waits.
pub fn place(view: &SessionView, waiting: Option<Delivery>) -> Place {
    if view.blocked == Some(Blocked::NoMachine) || waiting == Some(Delivery::Queued) {
        return Place::NoMachine;
    }
    if waiting == Some(Delivery::Resuming) {
        return Place::Resuming;
    }
    match view.state {
        State::Cloud => Place::Cloud,
        State::Resuming => Place::Resuming,
        State::ComingBack => Place::ComingBack,
        State::Local => Place::OnMac,
        State::Parked if waiting.is_some() => Place::Resuming,
        State::Parked => Place::Idle,
    }
}

/// One chat as a row, and as the open chat's header.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatRow {
    pub id: String,
    pub title: String,
    pub harness: String,
    pub place: Place,
    /// The person keeps the chat in the Cloud when a Mac returns.
    pub keep_in_cloud: bool,
    /// A Cloud machine has the chat: what "Keep in Cloud" applies to.
    pub in_cloud: bool,
    pub repo: Option<Repo>,
    /// Epoch milliseconds.
    pub updated_at: u64,
    /// Auto was switched off for the chat: nothing more will arrive.
    pub closed: bool,
}

impl ChatRow {
    pub fn of(view: &SessionView, waiting: Option<Delivery>) -> ChatRow {
        ChatRow {
            id: view.id.clone(),
            title: view.title.clone(),
            harness: view.harness.clone(),
            place: place(view, waiting),
            keep_in_cloud: view.keep_in_cloud,
            in_cloud: view.holder.is_vm(),
            repo: view.repo.clone(),
            updated_at: view.updated_at,
            closed: !view.auto,
        }
    }
}

/// The person's open Auto chats, newest first, and the repositories they work in.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatList {
    pub chats: Vec<ChatRow>,
    /// The repositories and branches of those chats, the most recently used first, each once.
    pub repos: Vec<Repo>,
    /// The person has more chats than [`MAX_PAGES`] pages hold.
    pub more: bool,
}

/// Reads the list page by page. It stops at the last page, at [`MAX_PAGES`], or when the store
/// answers a cursor it already gave (so a store that repeats itself cannot hold the phone).
pub async fn list<C: AutoCloud>(cloud: &C) -> CloudResult<ChatList> {
    let mut views: Vec<SessionView> = Vec::new();
    let mut cursor: Option<String> = None;
    let mut more = false;
    for page in 1..=MAX_PAGES {
        let answer = cloud.list(Some(PAGE), cursor.as_deref()).await?;
        views.extend(answer.sessions);
        match answer.next_cursor.filter(|next| !next.is_empty()) {
            Some(next) if cursor.as_ref() != Some(&next) => {
                more = page == MAX_PAGES;
                cursor = Some(next);
            }
            _ => {
                more = false;
                break;
            }
        }
    }
    let chats = views.iter().map(|view| ChatRow::of(view, None)).collect();
    Ok(ChatList { chats, repos: recent_repos(&views), more })
}

/// The repositories and branches `views` work in, the most recently used first, each once, at
/// most [`RECENT_REPOS`].
pub fn recent_repos(views: &[SessionView]) -> Vec<Repo> {
    let mut used: Vec<(u64, &Repo)> =
        views.iter().filter_map(|view| view.repo.as_ref().map(|repo| (view.updated_at, repo))).collect();
    used.sort_by_key(|used| std::cmp::Reverse(used.0));
    let mut repos: Vec<Repo> = Vec::new();
    for (_, repo) in used {
        if repos.len() < RECENT_REPOS && !repos.contains(repo) {
            repos.push(repo.clone());
        }
    }
    repos
}
