use serde_json::Value;

/// State used by the stream translator while one harness turn is active.
#[derive(Debug, Default)]
pub struct StreamState {
    pub open_message: Option<String>,
    pub retry_from: Option<(String, String)>,
    pub harness_error: Option<Value>,
    pub trailing_text: String,
    pub trailing_seqs: Vec<u64>,
    pub trailing_overflow: bool,
    pub reply_segment: Option<String>,
    pub reply_segments: u32,
    pub segment_turn: Option<String>,
    pub segment_message: Option<String>,
    pub plan_turn: Option<String>,
    pub plan_shown: bool,
}
