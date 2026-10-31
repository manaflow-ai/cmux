//! Drafts of the running turn's reply (parity item 4, `draft.rs`): the
//! turn runner makes them, the brain publishes them to the turn's
//! conversation, and the last one (`done`) after the reply is posted.

use super::Brain;

impl Brain {
    /// A draft of the running turn's reply goes to its conversation.
    pub(super) fn turn_draft(&mut self, draft: &crate::draft::Draft) {
        let Some(conversation) = self
            .state
            .turn
            .as_ref()
            .filter(|t| t.key == draft.turn)
            .and_then(|t| t.conversation.clone())
        else {
            return;
        };
        // A Chief that acts on its own may answer NO_REPLY in a channel:
        // no live text there, only the final draft that clears it.
        if self.settings.membership.acts_on_its_own()
            && !draft.done
            && self.state.conversation.as_deref() != Some(conversation.as_str())
        {
            return;
        }
        self.publish_draft(&conversation, draft);
    }

    /// Publishes a draft; a failure is logged once per process (drafts are
    /// display only, the posted reply is the record).
    pub(super) fn publish_draft(&mut self, conversation: &str, draft: &crate::draft::Draft) {
        let Some(daemon) = self.daemon.as_mut() else {
            return;
        };
        if let Err(e) = daemon.draft(conversation, draft)
            && !self.draft_failed
        {
            self.draft_failed = true;
            (self.log)(&format!(
                "publishing a reply draft failed: {e}; later failures are not logged"
            ));
        }
    }

    /// A change of the running turn's run record goes to its conversation
    /// (`conversation-run-append`). The brain adds what the turn runner does
    /// not know: the run's key as its reply's key, and the messages the reply
    /// answers. A failure is logged once per process (display only).
    pub(super) fn turn_run(&mut self, update: crate::run::RunUpdate) {
        let Some(turn) = self.state.turn.as_ref().filter(|t| t.key == update.turn) else {
            return;
        };
        let Some(conversation) = turn.conversation.clone() else {
            return;
        };
        // Live frames first (`chief-live-v1`), with the conversation and the
        // run (the turn key); display only, like the run.
        if !update.live.is_empty()
            && let Some(daemon) = self.daemon.as_mut()
        {
            for mut frame in update.live {
                frame["conversation"] = serde_json::json!(conversation);
                frame["run"] = serde_json::json!(update.turn);
                let sent = self.live_streams.send(&update.turn, frame, |frame| {
                    daemon.live_publish(&conversation, frame)
                });
                match sent {
                    Ok(()) => {}
                    Err(e) if !self.live_failed => {
                        self.live_failed = true;
                        (self.log)(&format!(
                            "sending a live run frame failed: {e}; later failures are not logged"
                        ));
                    }
                    Err(_) => {}
                }
            }
        }
        if update.run.is_empty() && update.steps.is_empty() && update.images.is_empty() {
            return;
        }
        let mut run = update.run;
        run.insert("id".into(), serde_json::json!(update.turn));
        run.insert("turn".into(), serde_json::json!(update.turn));
        if !turn.answers.is_empty() {
            let answers: Vec<&String> = turn.answers.iter().take(16).collect();
            run.insert("answers".into(), serde_json::json!(answers));
        }
        // A reply to a group message goes into that message's thread
        // (`reply_threads`): the run shows there while it works.
        let thread = self.reply_thread(&conversation, &turn.answers);
        if let Some((root, _)) = &thread {
            run.insert("thread_root".into(), serde_json::json!(root));
        }
        let Some(daemon) = self.daemon.as_mut() else {
            return;
        };
        // Pictures first: each becomes an attachment its step names, now and in later appends.
        let turn_key = update.turn.clone();
        self.run_attachments
            .retain(|(turn, _), _| *turn == turn_key);
        for image in &update.images {
            match upload_image(daemon.as_mut(), &conversation, image) {
                Ok(attachment) => self
                    .run_attachments
                    .entry((turn_key.clone(), image.step.clone()))
                    .or_default()
                    .push(attachment),
                Err(e) if !self.run_failed => {
                    self.run_failed = true;
                    (self.log)(&format!(
                        "uploading a run picture failed: {e}; later failures are not logged"
                    ));
                }
                Err(_) => {}
            }
        }
        let mut steps = update.steps;
        for step in &mut steps {
            let id = step
                .get("id")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default()
                .to_owned();
            if let Some(attachments) = self.run_attachments.get(&(turn_key.clone(), id)) {
                step["attachments"] = serde_json::json!(attachments);
            }
        }
        // The live browser card reads the same steps (browser_card.rs).
        self.browser_steps(&conversation, &turn_key, &mut steps, thread);
        let Some(daemon) = self.daemon.as_mut() else {
            return;
        };
        if let Err(e) = daemon.run_append(&conversation, serde_json::Value::Object(run), steps)
            && !self.run_failed
        {
            self.run_failed = true;
            (self.log)(&format!(
                "appending to the turn's run failed: {e}; later failures are not logged"
            ));
        }
    }
}

/// One run picture as an attachment of `conversation` (`{hash, name, mime_type, byte_count,
/// width, height}`): decoded to read its size, at most 4 MiB.
pub(super) fn upload_image(
    daemon: &mut dyn crate::daemon::ConversationPort,
    conversation: &str,
    image: &crate::run::RunImage,
) -> Result<serde_json::Value, String> {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(image.data.as_bytes())
        .map_err(|e| format!("picture data: {e}"))?;
    if bytes.is_empty() || bytes.len() > 4 * 1024 * 1024 {
        return Err(format!("picture of {} bytes", bytes.len()));
    }
    let (width, height) = image::ImageReader::new(std::io::Cursor::new(&bytes))
        .with_guessed_format()
        .map_err(|e| e.to_string())?
        .into_dimensions()
        .map_err(|e| e.to_string())?;
    let extension = image.mime_type.rsplit('/').next().unwrap_or("png");
    let name = format!("{}.{extension}", image.step.replace(':', "-"));
    let stored = daemon
        .upload_run_image(conversation, &bytes, &image.mime_type, &name, width, height)
        .map_err(|e| e.to_string())?;
    Ok(serde_json::json!({
        "hash": stored.hash,
        "name": name,
        "mime_type": stored.mime_type,
        "byte_count": stored.byte_count,
        "width": width,
        "height": height,
    }))
}
