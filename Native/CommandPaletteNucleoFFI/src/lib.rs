use std::cmp::Ordering;
use std::collections::BinaryHeap;
use std::slice;
use std::str;
use std::sync::Mutex;

use nucleo::pattern::{AtomKind, CaseMatching, Normalization, Pattern};
use nucleo::{Config, Matcher, Utf32Str};

#[repr(C)]
pub struct CmuxNucleoCandidateSpan {
    title_offset: usize,
    title_len: usize,
    search_offset: usize,
    search_len: usize,
    rank: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CmuxNucleoMatch {
    index: usize,
    score: f64,
    rank: i32,
}

struct Candidate {
    title: String,
    search_text: String,
    rank: i32,
    ascii_mask_low: u64,
    ascii_mask_high: u64,
}

struct ScoredCandidate {
    index: usize,
    score: f64,
    rank: i32,
}

struct WorstFirstScoredCandidate(ScoredCandidate);

impl PartialEq for WorstFirstScoredCandidate {
    fn eq(&self, other: &Self) -> bool {
        scored_candidate_order(&self.0, &other.0) == Ordering::Equal
    }
}

impl Eq for WorstFirstScoredCandidate {}

impl PartialOrd for WorstFirstScoredCandidate {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for WorstFirstScoredCandidate {
    fn cmp(&self, other: &Self) -> Ordering {
        scored_candidate_order(&self.0, &other.0)
    }
}

struct SearchState {
    matcher: Matcher,
    utf32_buf: Vec<char>,
}

impl SearchState {
    fn score_text(&mut self, pattern: &Pattern, text: &str) -> Option<u32> {
        self.utf32_buf.clear();
        pattern.score(Utf32Str::new(text, &mut self.utf32_buf), &mut self.matcher)
    }
}

pub struct CmuxNucleoIndex {
    candidates: Vec<Candidate>,
    state: Mutex<SearchState>,
}

#[no_mangle]
pub extern "C" fn cmux_nucleo_ffi_version() -> u32 {
    1
}

#[no_mangle]
pub unsafe extern "C" fn cmux_nucleo_index_create(
    blob_ptr: *const u8,
    blob_len: usize,
    spans_ptr: *const CmuxNucleoCandidateSpan,
    span_count: usize,
) -> *mut CmuxNucleoIndex {
    if blob_ptr.is_null() || spans_ptr.is_null() {
        return std::ptr::null_mut();
    }

    let blob = slice::from_raw_parts(blob_ptr, blob_len);
    let spans = slice::from_raw_parts(spans_ptr, span_count);
    let mut candidates = Vec::with_capacity(span_count);

    for span in spans {
        let Some(title) = text_from_blob(blob, span.title_offset, span.title_len) else {
            return std::ptr::null_mut();
        };
        let Some(search_text) = text_from_blob(blob, span.search_offset, span.search_len) else {
            return std::ptr::null_mut();
        };
        let (title_low, title_high) = ascii_mask(title);
        let (search_low, search_high) = ascii_mask(search_text);
        candidates.push(Candidate {
            title: title.to_owned(),
            search_text: search_text.to_owned(),
            rank: span.rank,
            ascii_mask_low: title_low | search_low,
            ascii_mask_high: title_high | search_high,
        });
    }

    Box::into_raw(Box::new(CmuxNucleoIndex {
        candidates,
        state: Mutex::new(SearchState {
            matcher: Matcher::new(Config::DEFAULT),
            utf32_buf: Vec::new(),
        }),
    }))
}

#[no_mangle]
pub unsafe extern "C" fn cmux_nucleo_index_destroy(index: *mut CmuxNucleoIndex) {
    if !index.is_null() {
        drop(Box::from_raw(index));
    }
}

#[no_mangle]
pub unsafe extern "C" fn cmux_nucleo_index_search(
    index: *mut CmuxNucleoIndex,
    query_ptr: *const u8,
    query_len: usize,
    result_limit: usize,
    out_matches: *mut CmuxNucleoMatch,
    out_capacity: usize,
    out_count: *mut usize,
) -> i32 {
    if index.is_null() || out_count.is_null() {
        return -1;
    }
    *out_count = 0;
    if result_limit == 0 || out_capacity == 0 {
        return 0;
    }
    if out_matches.is_null() || (query_ptr.is_null() && query_len > 0) {
        return -1;
    }

    let index = &*index;
    let query_bytes = if query_len == 0 {
        &[]
    } else {
        slice::from_raw_parts(query_ptr, query_len)
    };
    let Ok(query) = str::from_utf8(query_bytes) else {
        return -2;
    };

    let normalized_query = query.split_whitespace().collect::<Vec<_>>().join(" ");
    let output_limit = result_limit.min(out_capacity);
    let query_is_empty = normalized_query.is_empty();
    let output: Vec<CmuxNucleoMatch>;

    if query_is_empty {
        output = index
            .candidates
            .iter()
            .enumerate()
            .take(output_limit)
            .map(|(candidate_index, candidate)| CmuxNucleoMatch {
                index: candidate_index,
                score: 0.0,
                rank: candidate.rank,
            })
            .collect();
    } else {
        let query_mask = ascii_mask_query(&normalized_query);
        let pattern = Pattern::new(
            &normalized_query,
            CaseMatching::Ignore,
            Normalization::Smart,
            AtomKind::Fuzzy,
        );
        let mut state = index
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut best_matches = BinaryHeap::with_capacity(output_limit);

        for (candidate_index, candidate) in index.candidates.iter().enumerate() {
            if let Some((query_low, query_high)) = query_mask {
                if query_low & !candidate.ascii_mask_low != 0
                    || query_high & !candidate.ascii_mask_high != 0
                {
                    continue;
                }
            }

            let title_score = state.score_text(&pattern, &candidate.title);
            let search_score = state.score_text(&pattern, &candidate.search_text);
            let Some(score) = weighted_score(title_score, search_score) else {
                continue;
            };
            append_scored_candidate(
                ScoredCandidate {
                    index: candidate_index,
                    score,
                    rank: candidate.rank,
                },
                &mut best_matches,
                output_limit,
            );
        }

        let mut scored: Vec<ScoredCandidate> = best_matches
            .into_iter()
            .map(|candidate| candidate.0)
            .collect();
        scored.sort_by(scored_candidate_order);
        output = scored
            .into_iter()
            .map(|candidate| CmuxNucleoMatch {
                index: candidate.index,
                score: candidate.score,
                rank: candidate.rank,
            })
            .collect();
    }

    let count = output.len();
    std::ptr::copy_nonoverlapping(output.as_ptr(), out_matches, count);
    *out_count = count;
    0
}

fn append_scored_candidate(
    candidate: ScoredCandidate,
    best_matches: &mut BinaryHeap<WorstFirstScoredCandidate>,
    output_limit: usize,
) {
    if best_matches.len() < output_limit {
        best_matches.push(WorstFirstScoredCandidate(candidate));
        return;
    }

    let Some(worst_candidate) = best_matches.peek() else {
        return;
    };
    if scored_candidate_order(&candidate, &worst_candidate.0) != Ordering::Less {
        return;
    }
    best_matches.pop();
    best_matches.push(WorstFirstScoredCandidate(candidate));
}

fn text_from_blob(blob: &[u8], offset: usize, len: usize) -> Option<&str> {
    let end = offset.checked_add(len)?;
    if end > blob.len() {
        return None;
    }
    str::from_utf8(&blob[offset..end]).ok()
}

fn weighted_score(title_score: Option<u32>, search_score: Option<u32>) -> Option<f64> {
    match (title_score, search_score) {
        (Some(title), Some(search)) => Some(f64::from(search).max(f64::from(title) + 2_000.0)),
        (Some(title), None) => Some(f64::from(title) + 2_000.0),
        (None, Some(search)) => Some(f64::from(search)),
        (None, None) => None,
    }
}

fn scored_candidate_order(lhs: &ScoredCandidate, rhs: &ScoredCandidate) -> Ordering {
    rhs.score
        .total_cmp(&lhs.score)
        .then_with(|| lhs.rank.cmp(&rhs.rank))
        .then_with(|| lhs.index.cmp(&rhs.index))
}

fn ascii_mask_query(text: &str) -> Option<(u64, u64)> {
    if !text.is_ascii() {
        return None;
    }
    let mut low = 0;
    let mut high = 0;
    for byte in text.bytes() {
        if byte.is_ascii_whitespace() {
            continue;
        }
        set_ascii_mask_bit(byte.to_ascii_lowercase(), &mut low, &mut high);
    }
    Some((low, high))
}

fn ascii_mask(text: &str) -> (u64, u64) {
    let mut low = 0;
    let mut high = 0;
    for byte in text.bytes().filter(|byte| byte.is_ascii()) {
        set_ascii_mask_bit(byte.to_ascii_lowercase(), &mut low, &mut high);
    }
    (low, high)
}

fn set_ascii_mask_bit(byte: u8, low: &mut u64, high: &mut u64) {
    if byte < 64 {
        *low |= 1_u64 << u64::from(byte);
    } else if byte < 128 {
        *high |= 1_u64 << u64::from(byte - 64);
    }
}
