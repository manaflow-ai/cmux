//! The owner's `memory redescribe` (stub: refuses every note).

use serde_json::{Value, json};

impl super::Brain {
    /// Refuses every note (not built yet).
    pub(super) fn redescribe(&mut self, notes: &[u64]) -> Value {
        let refused: Vec<Value> = notes
            .iter()
            .map(|id| json!({"id": id, "why": "not built yet"}))
            .collect();
        json!({"started": [], "refused": refused})
    }

    /// Drops the answer (not built yet).
    pub(super) fn redescribed(
        &mut self,
        _note: u64,
        _image: &super::images::TurnImage,
        _description: Result<String, String>,
    ) {
    }
}
