//! `ChildAgent`: liveness, and writing to the harness (fenced writes, hand-on, codex and claude lines).

use super::*;

impl ChildAgent {
    /// The simulation's in-process agent ends, as a killed child does: its task stops and its
    /// stdout closes.
    #[cfg(feature = "sim")]
    pub(super) fn end_sim(&self) {
        if let Some(alive) = &self.sim_alive {
            alive.store(false, Ordering::SeqCst);
        }
    }

    pub async fn is_alive(&self) -> bool {
        if let Some(h) = &self.hosted {
            return !h.exit_seen.load(Ordering::SeqCst)
                && !h.broken.load(Ordering::SeqCst)
                && !h.link().is_closed();
        }
        #[cfg(feature = "sim")]
        if let Some(alive) = &self.sim_alive {
            return alive.load(Ordering::SeqCst);
        }
        let mut guard = self.child.lock().await;
        match guard.as_mut() {
            Some(child) => matches!(child.try_wait(), Ok(None)),
            None => false,
        }
    }

    pub(super) async fn write(&self, msg: &Message) -> Result<()> {
        self.write_fenced(msg, None).await
    }

    /// [`Self::write`], `fence` held to it: one line (or frame) each, so a cut drops it whole.
    pub(super) async fn write_fenced(&self, msg: &Message, fence: Option<&Fence>) -> Result<()> {
        if let Some(f) = fence {
            let _ = f.0.writer.set(match &self.hosted {
                Some(h) => Writer::Hosted(h.link().record.clone()),
                None => Writer::Direct {
                    child: Arc::downgrade(&self.child),
                    pid: self.pid,
                    stop: self.writer_stop.get().cloned(),
                },
            });
        }
        // Not handed to a writer (an error, or dropped while it waits for room): it is never
        // written, also once a translator took it (review 87 of #23322).
        let mut unsent = Unsent(fence);
        let handed = self.hand_on(msg, fence).await;
        if handed.is_ok() {
            unsent.0 = None;
        }
        handed
    }

    pub(super) async fn hand_on(&self, msg: &Message, fence: Option<&Fence>) -> Result<()> {
        if let Some(h) = &self.hosted {
            // The host writes it and logs it back as an `out` entry. An answer is kept until then,
            // whatever this write returns: a reattach sends it again if the host never took it.
            // Kept under the link's lock: a reattach swaps the link under it, so an answer written
            // through the old link is kept before the reattach looks (`resend_unlogged_answers`).
            let link = {
                let current = h.link.read_or_recover();
                if let Message::Response { id, .. } = msg {
                    let mut unlogged = h.unlogged_answers.lock_or_recover();
                    unlogged.retain(|a| a.id != key(id));
                    let link = Arc::downgrade(&current);
                    let (id, msg, fence) = (key(id), msg.to_value(), fence.cloned());
                    unlogged.push(UnloggedAnswer { id, msg, fence, link });
                }
                current.clone()
            };
            return link.line_fenced(msg.to_value(), fence.cloned()).await;
        }
        // A translator's state moves on with what it translates (Claude's permission asks, the
        // app-server's approvals), so a message it takes is as good as taken: never cut while
        // queued, which could leave its agent waiting on an ask the translator let go of; a cut
        // ends that agent instead (review 88 of #23322).
        if (self.codex.is_some() || self.translator.is_some()) && fence.is_some_and(|f| !f.begin())
        {
            return Err(anyhow!("agent {}: {FENCE_CUT}", self.name));
        }
        if let Some(cx) = &self.codex {
            let safe = crate::codex_app_server::redact(&msg.to_value());
            let safe_message = Message::from_value(safe).unwrap_or_else(|_| msg.clone());
            (self.tap)(Direction::Out, &safe_message, None);
            let order = cx.order.lock().await;
            let split = crate::codex_app_server::split(cx.tr.from_client(&msg.to_value()));
            let written = self.codex_lines(split.server, fence).await;
            drop(order);
            if !written {
                return Err(anyhow!("agent {} stdin closed", self.name));
            }
            self.codex_to_hub(cx, split.hub).await;
            return Ok(());
        }
        (self.tap)(Direction::Out, msg, None);
        if let Some(tr) = &self.translator {
            match tr.outbound(msg).await {
                crate::claude_stdio::Outbound::Lines(lines) => {
                    self.claude_lines(lines, fence).await
                }
                crate::claude_stdio::Outbound::Reply(reply) => {
                    if let Some(f) = fence.filter(|f| f.begin()) {
                        f.written();
                    }
                    self.answer_locally(reply).await;
                    Ok(())
                }
                // Written first, so Claude Code reads them; then answered without it.
                crate::claude_stdio::Outbound::LinesThenReply(lines, reply) => {
                    self.claude_lines(lines, fence).await?;
                    self.answer_locally(reply).await;
                    Ok(())
                }
            }
        } else {
            self.stdin_tx
                .send((msg.to_line(), fence.cloned()))
                .await
                .map_err(|_| anyhow!("agent {} stdin closed", self.name))
        }
    }

    /// The translator's own answer to a request of ours, as if claude replied.
    pub(super) async fn answer_locally(&self, reply: Message) {
        if let Message::Response { id, result, error } = reply
            && let Some(tx) = self.pending.lock().await.take(&id)
        {
            let _ = tx.send(match error {
                Some(e) => Err(e),
                None => Ok(result.unwrap_or(Value::Null)),
            });
        }
    }

    /// ACP messages the Codex translator produced for the hub: an answer
    /// to a request of ours resolves it, as if Codex replied; requests and
    /// notifications go to the session's inbound queue.
    pub(super) async fn codex_to_hub(&self, cx: &CodexLink, hub: Vec<Message>) {
        for m in hub {
            if !matches!(m, Message::Response { .. }) {
                (self.tap)(Direction::In, &m, None);
            }
            match m {
                Message::Response { id, result, error } => {
                    if let Some(tx) = self.pending.lock().await.take(&id) {
                        let _ = tx.send(match error {
                            Some(e) => Err(e),
                            None => Ok(result.unwrap_or(Value::Null)),
                        });
                    }
                }
                Message::Request { id, method, params } => {
                    let _ = cx
                        .inbound
                        .send(Inbound::Request {
                            id,
                            method,
                            params,
                            host_seq: None,
                            host_incarnation: Some(self.direct_incarnation()),
                        })
                        .await;
                }
                Message::Notification { method, params } => {
                    let _ = cx
                        .inbound
                        .send(Inbound::Notification {
                            method,
                            params,
                            host_seq: None,
                            host_incarnation: Some(self.direct_incarnation()),
                            persisted: None,
                            agent: self.generation,
                        })
                        .await;
                }
            }
        }
    }

    /// Writes the Claude translator's stream-json lines to the agent's stdin, each logged.
    pub(super) async fn claude_lines(
        &self,
        lines: Vec<Value>,
        fence: Option<&Fence>,
    ) -> Result<()> {
        // Nothing for the agent (a late answer to a withdrawn elicitation): nothing is queued,
        // as before the fence (review 82 of #23322), and a fenced one is settled.
        if lines.is_empty() {
            if let Some(f) = fence.filter(|f| f.begin()) {
                f.written();
            }
            return Ok(());
        }
        let mut s = String::new();
        for l in lines {
            (self.tap)(Direction::Out, &Message::notification("claude.stdin", l.clone()), None);
            s.push_str(&format!("{l}\n"));
        }
        self.stdin_tx
            .send((s, fence.cloned()))
            .await
            .map_err(|_| anyhow!("agent {} stdin closed", self.name))
    }

    /// Writes translator lines to the app-server's stdin, each logged.
    /// Returns false once stdin is closed.
    pub(super) async fn codex_lines(&self, lines: Vec<Value>, fence: Option<&Fence>) -> bool {
        // Nothing for the app-server (the translator answered itself): nothing is queued, so
        // this never waits on a full stdin (review 81 of #23322), and a fenced message is
        // settled, as nothing of it is left to write.
        if lines.is_empty() {
            if let Some(f) = fence.filter(|f| f.begin()) {
                f.written();
            }
            return true;
        }
        let mut s = String::new();
        for l in lines {
            let safe = crate::codex_app_server::redact(&l);
            (self.tap)(
                Direction::Out,
                &Message::notification(crate::codex_app_server::STDIN_KIND, safe),
                None,
            );
            s.push_str(&crate::codex_app_server::line(&l));
        }
        self.stdin_tx.send((s, fence.cloned())).await.is_ok()
    }

    /// Queue [`Inbound::ReplayDone`] behind what the reader queued so far, waiting for room.
    /// False when the queue is closed.
    pub async fn queue_replay_done(&self) -> bool {
        self.inbound.send(Inbound::ReplayDone { agent: self.generation }).await.is_ok()
    }

    /// Where a cancelled request's `$/cancel_request` goes ([`Abandoned`]).
    pub(super) fn cancel_sink(&self) -> CancelSink {
        if let Some(h) = &self.hosted {
            CancelSink::Hosted(h.link())
        } else if self.translator.is_some() || self.codex.is_some() {
            CancelSink::None
        } else {
            CancelSink::Direct(self.stdin_tx.clone())
        }
    }
}
