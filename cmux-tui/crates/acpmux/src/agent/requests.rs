//! `ChildAgent`: requests, notifications, responses and replay waits.

use super::*;

impl ChildAgent {
    /// Send a request and wait for its response.
    pub async fn request(&self, method: &str, params: Value) -> Result<Value, RpcError> {
        self.request_with_hook(method, params, None, || {}).await
    }

    /// Send a request and run `on_written` only after its frame reached the agent write path.
    /// Used by first-message title generation to start beside the turn, after the harness can
    /// publish its own session title. `fence`: held to the request's write; once cut, the
    /// request fails.
    pub async fn request_with_hook<F: FnOnce()>(
        &self,
        method: &str,
        params: Value,
        fence: Option<&Fence>,
        on_written: F,
    ) -> Result<Value, RpcError> {
        self.request_hook(method, params, fence, false, on_written).await
    }

    /// Like `request_with_hook`, but the callback requires confirmation from the stdin writer
    /// (or hosted harness receipt), not acceptance into the transport queue.
    pub(crate) async fn request_with_confirmed_hook<F: FnOnce()>(
        &self,
        method: &str,
        params: Value,
        fence: Option<&Fence>,
        on_written: F,
    ) -> Result<Value, RpcError> {
        let own_fence = Fence::default();
        let fence = fence.unwrap_or(&own_fence);
        let _unsent = CutOnDrop(Some(fence));
        self.request_hook(method, params, Some(fence), true, on_written).await
    }

    pub(super) async fn request_hook<F: FnOnce()>(
        &self,
        method: &str,
        params: Value,
        fence: Option<&Fence>,
        confirmed: bool,
        on_written: F,
    ) -> Result<Value, RpcError> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        {
            let mut p = self.pending.lock().await;
            // A link that broke on an entry it could not store (`start_reader`) is marked under
            // this lock, and its notice answers every request open then: one added after it would
            // wait for a reattach nothing starts. It is answered now; the next request reattaches.
            if self.is_broken() {
                return Err(RpcError::internal(LINK_UNLOGGED));
            }
            p.map.insert(key(&Value::from(id)), tx);
        }
        let mut abandoned = Abandoned {
            pending: self.pending.clone(),
            sink: self.cancel_sink(),
            id,
            method: method.to_owned(),
            armed: true,
            forget_on_drop: false,
        };
        let msg = Message::request(id, method, params);
        let answer = async {
            // Dropped before its message is handed on (a turn that ends first): it is cut, so
            // no holder waits on it.
            let mut unhanded = CutOnDrop(fence);
            self.write_fenced(&msg, fence).await.map_err(|e| RpcError::internal(e.to_string()))?;
            unhanded.0 = None;
            let mut rx = rx;
            if confirmed && let Some(fence) = fence {
                // A legacy host may answer without a write receipt. Return its answer, but
                // never consume information or report read from an unconfirmed transport.
                tokio::select! {
                    () = fence.settled() => {}
                    answer = &mut rx => {
                        // A direct child may answer its line before its writer, preempted
                        // between the write and `written()`, marks it: every direct writer
                        // settles it, so that answer waits for it. Only a host can answer with
                        // no receipt to come.
                        if self.hosted.is_none() { fence.settled().await; }
                        if fence.now() == Fence::WRITTEN { on_written(); }
                        return answer.unwrap_or_else(|_| Err(RpcError::internal("agent response channel dropped")));
                    }
                }
                if fence.now() != Fence::WRITTEN {
                    return Err(RpcError::internal(
                        "agent process closed before the prompt write was confirmed",
                    ));
                }
            }
            on_written();
            // A line whose write failed never reaches its agent, so no answer comes: a writer
            // that panicked on it (#54378) answers it here, where before it waited forever.
            let never_written = async {
                match fence {
                    Some(f) => {
                        f.settled().await;
                        if f.now() != Fence::FAILED {
                            std::future::pending::<()>().await;
                        }
                    }
                    None => std::future::pending().await,
                }
            };
            let answer = tokio::select! {
                answer = rx => answer,
                () = never_written => {
                    return Err(RpcError::internal("the agent's line was never written"));
                }
            };
            // No answer proves its line was written: an error may be this side's own "closed" or
            // made up by a translator once its harness's output ended, and a translator answers
            // prompts it gave up on too (Claude's `cancelled`). A direct agent's writer, a host's
            // receipt or its end settle it (review 87 of #23322).
            answer.unwrap_or_else(|_| Err(RpcError::internal("agent response channel dropped")))
        };
        let cut = async {
            match fence {
                Some(f) => f.was_cut().await,
                None => std::future::pending().await,
            }
        };
        let answer = tokio::select! {
            answer = answer => answer,
            () = cut => Err(RpcError::internal(FENCE_CUT)),
        };
        abandoned.armed = false;
        if answer.is_err() {
            // Not written by now, it never is: its answer is not awaited.
            if let Some(f) = fence {
                f.cut();
            }
            self.pending.lock().await.map.remove(&key(&Value::from(id)));
        }
        answer
    }

    /// [`Self::request`], given up after `limit`: the pending entry goes too, so an agent that
    /// never answers leaves nothing waiting, and a late answer to this id (never reused: ids
    /// only grow) finds no one and is dropped. None on timeout.
    pub async fn request_within(
        &self,
        method: &str,
        params: Value,
        limit: std::time::Duration,
    ) -> Option<Result<Value, RpcError>> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.map.insert(key(&Value::from(id)), tx);
        // Dropped before its answer (review F4 of #41285): its entry goes, and under its client's
        // cancel the agent hears it too, as for `request`.
        let mut abandoned = Abandoned {
            pending: self.pending.clone(),
            sink: self.cancel_sink(),
            id,
            method: method.to_owned(),
            armed: true,
            forget_on_drop: true,
        };
        let msg = Message::request(id, method, params);
        if let Err(e) = self.write(&msg).await {
            abandoned.armed = false;
            self.pending.lock().await.map.remove(&key(&Value::from(id)));
            return Some(Err(RpcError::internal(e.to_string())));
        }
        let answer = tokio::time::timeout(limit, rx).await;
        abandoned.armed = false;
        match answer {
            Ok(answer) => Some(
                answer
                    .unwrap_or_else(|_| Err(RpcError::internal("agent response channel dropped"))),
            ),
            Err(_) => {
                self.pending.lock().await.map.remove(&key(&Value::from(id)));
                None
            }
        }
    }

    pub async fn notify(&self, method: &str, params: Value) -> Result<()> {
        self.write(&Message::notification(method, params)).await
    }

    /// Answer a request the agent sent to us.
    pub async fn respond(&self, id: Id, result: Result<Value, RpcError>) -> Result<()> {
        self.respond_fenced(id, result, None).await
    }

    /// [`Self::respond`], `fence` held to the answer's write.
    pub async fn respond_fenced(
        &self,
        id: Id,
        result: Result<Value, RpcError>,
        fence: Option<&Fence>,
    ) -> Result<()> {
        let msg = match result {
            Ok(v) => Message::ok(id, v),
            Err(e) => Message::err(id, e),
        };
        self.write_fenced(&msg, fence).await
    }

    /// Register interest in the response to a request a previous controller
    /// sent this agent (a recovered turn); it arrives like any other.
    pub async fn await_response(&self, id: Id) -> oneshot::Receiver<Result<Value, RpcError>> {
        let (tx, rx) = oneshot::channel();
        let mut p = self.pending.lock().await;
        let orphan =
            p.orphans.iter().position(|(k, _)| *k == key(&id)).and_then(|i| p.orphans.remove(i));
        if let Some((_, answer)) = orphan {
            let _ = tx.send(answer);
        } else {
            p.map.insert(key(&id), tx);
        }
        rx
    }

    /// Wait until the entries through `h` are in the session log, as long as
    /// they keep coming: it gives up when no entry is logged for `stall` (a
    /// stalled, broken or closed link), and in any case after `ceiling`, so
    /// one large replay cannot hold daemon startup without end.
    pub async fn wait_replayed(
        &self,
        h: u64,
        stall: std::time::Duration,
        ceiling: std::time::Duration,
    ) -> bool {
        let Some(hosted) = &self.hosted else { return true };
        let mut rx = hosted.logged.subscribe();
        let progress = async {
            loop {
                if *rx.borrow_and_update() >= h {
                    return true;
                }
                // `changed` ends only with progress: the sender lives as long
                // as this agent, so a dead link ends the wait by the stall.
                if tokio::time::timeout(stall, rx.changed()).await.is_err() {
                    return false;
                }
            }
        };
        tokio::time::timeout(ceiling, progress).await.unwrap_or(false)
    }

    /// Whether the agent answers now: a hosted agent's host answers a query
    /// within `budget` (a wedged host keeps its link open but never
    /// answers); a direct child is alive.
    pub async fn answers_within(&self, budget: std::time::Duration) -> bool {
        if let Some(h) = &self.hosted {
            return h.link().query_within(budget).await.is_ok();
        }
        self.is_alive().await
    }
}
