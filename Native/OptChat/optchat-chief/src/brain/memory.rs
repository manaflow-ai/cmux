//! The brain's side of the memory files (memory_files.rs): the store every
//! turn's `<chief-memory>` block reads, and the self-paced check-ins
//! (check_in.rs) that wake the Chief on its open loops.

use std::sync::Arc;

use super::Brain;

impl Brain {
    /// The memory files every turn's `<chief-memory>` block comes from.
    pub fn set_memory_files(&mut self, files: Arc<crate::memory_files::MemoryFiles>) {
        self.memory_files = Some(files);
    }

    /// The self-paced check-in mode (check_in.rs).
    pub fn set_check_ins(&mut self, mode: crate::check_in::Mode) {
        self.check_ins = mode;
    }

    /// When the next check-in slot comes, on the brain's clock (None: off,
    /// or no memory files).
    pub(super) fn next_check_in(&self) -> Option<std::time::Instant> {
        let files = self.memory_files.as_ref()?;
        let now = chrono::Local::now().fixed_offset();
        // Today's slot not taken yet (the host started after it): now.
        if let Some(slot) = crate::check_in::current_slot(self.check_ins, now)
            && files.meta("check_in.last").as_deref() != Some(slot.as_str())
        {
            return Some(std::time::Instant::now());
        }
        let at = crate::check_in::next_slot(self.check_ins, now)?;
        let wait = (at - now).to_std().ok()?;
        Some(std::time::Instant::now() + wait)
    }

    /// At a check-in slot not taken yet today: wakes the Chief with its open
    /// loops, or takes the slot quietly when there are none.
    pub(super) fn fire_check_in(&mut self) {
        let Some(files) = self.memory_files.clone() else {
            return;
        };
        let now = chrono::Local::now().fixed_offset();
        let Some(slot) = crate::check_in::current_slot(self.check_ins, now) else {
            return;
        };
        if files.meta("check_in.last").as_deref() == Some(slot.as_str()) {
            return;
        }
        let _ = files.put_meta("check_in.last", &slot);
        let loops: Vec<(String, String)> = files
            .loops()
            .into_iter()
            .map(|r| (r.path, r.description))
            .collect();
        if loops.is_empty() {
            (self.log)(&format!("check-in {slot}: no open loops, no wake"));
            return;
        }
        (self.log)(&format!(
            "check-in {slot}: {} open loop(s), waking",
            loops.len()
        ));
        let text = crate::check_in::note(&loops, &slot);
        self.queue(text, super::Source::Note);
    }
}
