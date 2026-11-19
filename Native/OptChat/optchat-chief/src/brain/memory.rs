//! The brain's side of the memory files (memory_files.rs): the store every
//! turn's `<chief-memory>` block reads, and the self-paced check-ins
//! (check_in.rs) that wake the Chief on its open loops.

use std::sync::Arc;

use super::Brain;

impl Brain {
    /// The memory files every turn's `<chief-memory>` block comes from.
    pub fn set_memory_files(&mut self, files: Arc<crate::memory_files::MemoryFiles>) {
        self.check_in_last = files.meta(CHECK_IN_KEY);
        self.memory_files = Some(files);
    }

    /// The self-paced check-in mode (check_in.rs).
    pub fn set_check_ins(&mut self, mode: crate::check_in::Mode) {
        self.check_ins = mode;
    }

    /// When the next check-in slot comes, on the brain's clock (None: off,
    /// or no memory files). At most 5 minutes away, so the wall clock is read
    /// again after the Mac slept (`Instant` stops in sleep).
    pub(super) fn next_check_in(&self) -> Option<std::time::Instant> {
        self.memory_files.as_ref()?;
        let now = chrono::Local::now().fixed_offset();
        // Today's slot not taken yet (the host started after it): now.
        if let Some(slot) = crate::check_in::current_slot(self.check_ins, now)
            && self.check_in_last.as_deref() != Some(slot.as_str())
        {
            return Some(std::time::Instant::now());
        }
        let at = crate::check_in::next_slot(self.check_ins, now)?;
        let wait = (at - now).to_std().ok()?.min(CHECK_IN_RECHECK);
        Some(std::time::Instant::now() + wait)
    }

    /// At a check-in slot not taken yet: wakes the Chief with its open loops,
    /// or takes the slot quietly when there are none. The slot is taken in
    /// memory first, so a store that fails never wakes the Chief twice.
    pub(super) fn fire_check_in(&mut self) {
        let Some(files) = self.memory_files.clone() else {
            return;
        };
        let now = chrono::Local::now().fixed_offset();
        let Some(slot) = crate::check_in::current_slot(self.check_ins, now) else {
            return;
        };
        if self.check_in_last.as_deref() == Some(slot.as_str()) {
            return;
        }
        self.check_in_last = Some(slot.clone());
        if let Err(e) = files.put_meta(CHECK_IN_KEY, &slot) {
            (self.log)(&format!(
                "check-in {slot}: not saved ({e}); it may come again after a restart"
            ));
        }
        let loops: Vec<String> = files
            .loops()
            .iter()
            .map(crate::memory_files::index_line)
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

    /// The `<chief-memory>` block of the turn starting now (the whole block
    /// in the owner's turn, the loops only in another person's) and whether
    /// the last turn read the same block (a kept session then has it).
    pub(super) fn turn_memory_block(&mut self) -> (Option<String>, bool) {
        let block = self.memory_files.as_ref().and_then(|files| {
            if self.turn_ask {
                files.outside_block()
            } else {
                files.block()
            }
        });
        let same = block.is_some() && block == self.last_memory_block;
        self.last_memory_block = block.clone();
        (block, same)
    }
}

/// Where the last taken check-in slot is kept.
const CHECK_IN_KEY: &str = "check_in.last";
/// The longest wait before the check-in clock is read again.
const CHECK_IN_RECHECK: std::time::Duration = std::time::Duration::from_secs(300);
