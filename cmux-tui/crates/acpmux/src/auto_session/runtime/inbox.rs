//! The Cloud inbox into the chat: every message becomes a prompt of the chat exactly once.
//!
//! The store drops a message once the holder acks it, so the ack must not be the only thing
//! between the store's copy and the chat's queue. A drain therefore goes in this order:
//!
//! 1. Each message this chat has not taken is written into the chat's own log as an
//!    `auto_inbox` record, and the log is made durable.
//! 2. The store is told the messages are taken (the ack).
//! 3. Each one is given to the chat as a prompt whose id is the message's id.
//!
//! A daemon that stops after the ack finds the record with no prompt of that id and gives the
//! message to the chat again (`Hub::auto_inbox_owed`); one that stops before the ack reads the
//! message again, and the prompt id says it was taken. A message is never a prompt twice: the
//! chat's prompt ledger and log refuse an id they hold.

use std::sync::Arc;

use cmux_auto_session::AutoCloud;
use cmux_auto_session::wire::{Fence, InboxAck};
use serde_json::json;
use tokio::sync::oneshot;

use super::tasks::Ctx;
use crate::hub::{AUTO_CLIENT, Hub, PromptOptions, Session};

/// The most pages one drain reads: the store answers at most 64 messages a page.
const PAGES_MAX: usize = 64;

/// Gives the chat one message as a prompt. It returns once the chat recorded the prompt (it
/// started a turn or waits in the queue), not when its turn ends.
async fn deliver(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    id: &str,
    text: &str,
) -> Result<(), String> {
    let (accepted, recorded) = oneshot::channel();
    let options = PromptOptions {
        prompt_id: Some(id.to_owned()),
        // The id is looked up in the log too, which outlives a restart.
        resend: true,
        on_accepted: Some(Box::new(move |_| {
            let _ = accepted.send(());
        })),
        ..PromptOptions::default()
    };
    let blocks = vec![json!({"type": "text", "text": text})];
    let (owner, chat) = (hub.clone(), session.clone());
    // The hub's own task, as a prompt from a connection is: the turn outlives this drain.
    let turn = hub.scope.spawn_named("auto-session inbox prompt", async move {
        owner.prompt_with(&chat, blocks, AUTO_CLIENT, false, options).await
    });
    if recorded.await.is_ok() {
        return Ok(());
    }
    // Nothing was recorded: the prompt ended first, and says why.
    match turn.await {
        Ok(Ok(_)) => Ok(()),
        Ok(Err(error)) => Err(error.message),
        Err(error) => Err(error.to_string()),
    }
}

/// Gives the chat every message its log holds that no prompt of it took: what an earlier drain
/// acked and could not deliver.
async fn deliver_owed(hub: &Arc<Hub>, session: &Arc<Session>) -> Result<(), String> {
    let (reader, chat) = (hub.clone(), session.clone());
    let owed = tokio::task::spawn_blocking(move || reader.auto_inbox_owed(&chat))
        .await
        .map_err(|error| error.to_string())?;
    for (id, text) in owed {
        deliver(hub, session, &id, &text).await?;
    }
    Ok(())
}

/// `DrainInbox`: reads the inbox, makes its messages the chat's own, acks them and gives them
/// to the chat, oldest first.
pub(super) async fn drain<C: AutoCloud + 'static>(
    ctx: &Ctx<C>,
    id: &str,
    fence: Fence,
) -> Result<(), String> {
    let Some(session) = ctx.hub.auto_session(id) else {
        return Err("the chat is not on this machine".to_owned());
    };
    let mut after = 0;
    for _page in 0..PAGES_MAX {
        let messages = ctx.cloud.inbox(id, after).await.map_err(|error| error.to_string())?;
        let Some(through) = messages.iter().map(|message| message.n).max() else { break };
        let (hub, chat, page) = (ctx.hub.clone(), session.clone(), messages);
        tokio::task::spawn_blocking(move || -> anyhow::Result<()> {
            let logged = hub.auto_inbox_logged(&chat);
            for message in &page {
                let held = logged.iter().any(|(id, _)| *id == message.id);
                if !held && !hub.auto_took_prompt(&chat, &message.id) {
                    hub.auto_log_inbox(&chat, message.n, &message.id, &message.text);
                }
            }
            hub.auto_flush(&chat)
        })
        .await
        .map_err(|error| error.to_string())?
        .map_err(|error| format!("the chat's log could not be made durable: {error:#}"))?;
        let ack = InboxAck { holder: fence.holder.clone(), epoch: fence.epoch, through };
        ctx.cloud.ack_inbox(id, &ack).await.map_err(|error| error.to_string())?;
        after = through;
    }
    deliver_owed(&ctx.hub, &session).await
}
