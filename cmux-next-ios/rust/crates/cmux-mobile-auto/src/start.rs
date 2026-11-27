//! A chat started from the phone, with no laptop: a repository and branch, and a first message.
//! The person's Auto machine runs it.

use cmux_auto_session::cloud::{AutoCloud, AutoCloudError, CloudResult};
use cmux_auto_session::wire::{CreateRequest, ErrorCode, FirstMessage, Repo};
use serde::{Deserialize, Serialize};

use crate::rows::ChatRow;

/// The agent a chat started from the phone runs. A phone's Cloud chat starts Claude, as the
/// chats it starts through a paired Mac do.
pub const HARNESS: &str = "claude";

/// What the person filled in.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewChat {
    /// The repository's remote.
    pub remote: String,
    pub branch: String,
    /// The first message's id. The chat's id comes from it, so the same request again after a
    /// lost answer reaches the chat the first one made.
    pub message_id: String,
    pub text: String,
}

/// How a start ended.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub enum Started {
    /// The chat exists; a machine is being started for it.
    Chat { chat: ChatRow },
    /// The person has no Auto machine. Nothing was started.
    NoMachine,
    /// A field is empty. Nothing was sent.
    Incomplete,
}

/// Whether the person has an Auto machine: asked before a new chat is offered, so the phone
/// says the one line instead of taking a message it cannot start.
pub async fn has_machine<C: AutoCloud>(cloud: &C) -> CloudResult<bool> {
    match cloud.machine().await {
        Ok(_) => Ok(true),
        Err(error) if error.code() == Some(ErrorCode::NoMachine) => Ok(false),
        Err(error) => Err(error),
    }
}

/// Starts the chat. A request that got no answer is sent once more as it is: the store makes
/// one chat for one first message id.
pub async fn start<C: AutoCloud>(cloud: &C, new: &NewChat) -> CloudResult<Started> {
    let (remote, branch) = (new.remote.trim(), new.branch.trim());
    if remote.is_empty() || branch.is_empty() || new.text.trim().is_empty() || new.message_id.is_empty() {
        return Ok(Started::Incomplete);
    }
    let request = CreateRequest {
        title: None,
        harness: HARNESS.to_owned(),
        repo: Repo { remote: remote.to_owned(), branch: branch.to_owned() },
        first_message: FirstMessage { id: new.message_id.clone(), text: new.text.clone() },
    };
    let answer = match cloud.create(&request).await {
        Err(error) if error.retryable() => cloud.create(&request).await,
        answer => answer,
    };
    match answer {
        Ok(view) => Ok(Started::Chat { chat: ChatRow::of(&view, None) }),
        Err(error) if no_machine(&error) => Ok(Started::NoMachine),
        Err(error) => Err(error),
    }
}

fn no_machine(error: &AutoCloudError) -> bool {
    error.code() == Some(ErrorCode::NoMachine)
}
