use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::BinaryHeap;
use std::slice;
use std::str;

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
    title_lowercase: String,
    search_text: String,
    search_lines: Vec<String>,
    rank: i32,
    ascii_prefilter_safe: bool,
    ascii_mask_low: u64,
    ascii_mask_high: u64,
    title_initials: Vec<char>,
    title_char_count: usize,
}

struct ScoredCandidate {
    index: usize,
    score: f64,
    rank: i32,
}

struct InitialismQuery {
    chars: Vec<char>,
}

struct SearchToken {
    text: String,
    pattern: Pattern,
    initialism_query: Option<InitialismQuery>,
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
}

thread_local! {
    static SEARCH_STATE: RefCell<SearchState> = RefCell::new(SearchState {
        matcher: Matcher::new(Config::DEFAULT),
        utf32_buf: Vec::new(),
    });
}

#[no_mangle]
pub extern "C" fn cmux_nucleo_ffi_version() -> u32 {
    2
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
        let ascii_prefilter_safe = title.is_ascii() && search_text.is_ascii();
        let title_lowercase = title.to_lowercase();
        let (title_low, title_high) = ascii_mask(title);
        let (search_low, search_high) = ascii_mask(search_text);
        let title_initials = title_word_initials(title);
        let title_char_count = title.chars().count();
        let search_lines = search_text.lines().map(str::to_owned).collect();
        candidates.push(Candidate {
            title: title.to_owned(),
            title_lowercase,
            search_text: search_text.to_owned(),
            search_lines,
            rank: span.rank,
            ascii_prefilter_safe,
            ascii_mask_low: title_low | search_low,
            ascii_mask_high: title_high | search_high,
            title_initials,
            title_char_count,
        });
    }

    Box::into_raw(Box::new(CmuxNucleoIndex { candidates }))
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
    cmux_nucleo_index_search_impl(
        index,
        query_ptr,
        query_len,
        result_limit,
        std::ptr::null(),
        0,
        out_matches,
        out_capacity,
        out_count,
    )
}

#[no_mangle]
pub unsafe extern "C" fn cmux_nucleo_index_search_with_boosts(
    index: *mut CmuxNucleoIndex,
    query_ptr: *const u8,
    query_len: usize,
    result_limit: usize,
    boosts_ptr: *const i32,
    boosts_count: usize,
    out_matches: *mut CmuxNucleoMatch,
    out_capacity: usize,
    out_count: *mut usize,
) -> i32 {
    cmux_nucleo_index_search_impl(
        index,
        query_ptr,
        query_len,
        result_limit,
        boosts_ptr,
        boosts_count,
        out_matches,
        out_capacity,
        out_count,
    )
}

unsafe fn cmux_nucleo_index_search_impl(
    index: *mut CmuxNucleoIndex,
    query_ptr: *const u8,
    query_len: usize,
    result_limit: usize,
    boosts_ptr: *const i32,
    boosts_count: usize,
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
    let boosts = if boosts_ptr.is_null() && boosts_count == 0 {
        None
    } else if boosts_ptr.is_null() || boosts_count != index.candidates.len() {
        return -3;
    } else {
        Some(slice::from_raw_parts(boosts_ptr, boosts_count))
    };

    let normalized_query = query.split_whitespace().collect::<Vec<_>>().join(" ");
    let output_limit = result_limit.min(out_capacity);
    let query_is_empty = normalized_query.is_empty();
    let output: Vec<CmuxNucleoMatch>;

    if query_is_empty {
        let mut best_matches = BinaryHeap::with_capacity(output_limit);
        for (candidate_index, candidate) in index.candidates.iter().enumerate() {
            append_scored_candidate(
                ScoredCandidate {
                    index: candidate_index,
                    score: candidate_boost(boosts, candidate_index),
                    rank: candidate.rank,
                },
                &mut best_matches,
                output_limit,
            );
        }
        output = sorted_output(best_matches);
    } else {
        let query_mask = ascii_mask_query(&normalized_query);
        let search_tokens = search_tokens(&normalized_query);
        let normalized_query_lowercase = normalized_query.to_lowercase();
        let mut best_matches = BinaryHeap::with_capacity(output_limit);

        SEARCH_STATE.with(|state| {
            let mut state = state.borrow_mut();
            for (candidate_index, candidate) in index.candidates.iter().enumerate() {
                if candidate.ascii_prefilter_safe {
                    if let Some((query_low, query_high)) = query_mask {
                        if query_low & !candidate.ascii_mask_low != 0
                            || query_high & !candidate.ascii_mask_high != 0
                        {
                            continue;
                        }
                    }
                }

                let Some(score) = weighted_query_score(
                    &mut state,
                    &normalized_query,
                    &normalized_query_lowercase,
                    &search_tokens,
                    candidate,
                ) else {
                    continue;
                };
                append_scored_candidate(
                    ScoredCandidate {
                        index: candidate_index,
                        score: score + candidate_boost(boosts, candidate_index),
                        rank: candidate.rank,
                    },
                    &mut best_matches,
                    output_limit,
                );
            }
        });

        output = sorted_output(best_matches);
    }

    let count = output.len();
    std::ptr::copy_nonoverlapping(output.as_ptr(), out_matches, count);
    *out_count = count;
    0
}

fn candidate_boost(boosts: Option<&[i32]>, candidate_index: usize) -> f64 {
    boosts
        .and_then(|values| values.get(candidate_index))
        .map(|boost| f64::from(*boost))
        .unwrap_or(0.0)
}

fn sorted_output(best_matches: BinaryHeap<WorstFirstScoredCandidate>) -> Vec<CmuxNucleoMatch> {
    let mut scored: Vec<ScoredCandidate> = best_matches
        .into_iter()
        .map(|candidate| candidate.0)
        .collect();
    scored.sort_by(scored_candidate_order);
    scored
        .into_iter()
        .map(|candidate| CmuxNucleoMatch {
            index: candidate.index,
            score: candidate.score,
            rank: candidate.rank,
        })
        .collect()
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

fn search_tokens(query: &str) -> Vec<SearchToken> {
    query
        .split_whitespace()
        .map(|token| SearchToken {
            text: token.to_owned(),
            pattern: Pattern::new(
                token,
                CaseMatching::Ignore,
                Normalization::Smart,
                AtomKind::Fuzzy,
            ),
            initialism_query: initialism_query(token),
        })
        .collect()
}

fn weighted_query_score(
    state: &mut SearchState,
    query: &str,
    query_lowercase: &str,
    tokens: &[SearchToken],
    candidate: &Candidate,
) -> Option<f64> {
    let mut total_score = if tokens.len() == 1 {
        weighted_token_score(state, &tokens[0], candidate)?
    } else {
        let mut score = 0.0;
        for token in tokens {
            score += weighted_token_score(state, token, candidate)?;
        }
        score
    };

    if let Some(exact_query_line_score) = exact_search_text_line_score(candidate, query) {
        total_score = total_score.max(exact_query_line_score);
    }
    if let Some(title_phrase_score) = title_phrase_score(candidate, query_lowercase, tokens.len()) {
        total_score = total_score.max(title_phrase_score);
    }
    Some(total_score)
}

fn weighted_token_score(
    state: &mut SearchState,
    token: &SearchToken,
    candidate: &Candidate,
) -> Option<f64> {
    let title_score = state.score_text(&token.pattern, &candidate.title);
    let search_score = best_search_line_score(state, &token.pattern, candidate);
    weighted_score(
        &token.text,
        token.initialism_query.as_ref(),
        candidate,
        title_score,
        search_score,
    )
}

fn best_search_line_score(
    state: &mut SearchState,
    pattern: &Pattern,
    candidate: &Candidate,
) -> Option<u32> {
    let mut best_score: Option<u32> = None;
    for line in &candidate.search_lines {
        if line.trim().is_empty() {
            continue;
        }
        if let Some(score) = state.score_text(pattern, line) {
            best_score = Some(best_score.map_or(score, |best| best.max(score)));
        }
    }
    best_score
}

fn weighted_score(
    query: &str,
    initialism_query: Option<&InitialismQuery>,
    candidate: &Candidate,
    title_score: Option<u32>,
    search_score: Option<u32>,
) -> Option<f64> {
    let initialism_score =
        initialism_query.and_then(|query| title_initialism_score(query, candidate));
    let exact_search_text_score = exact_search_text_line_score(candidate, query);
    match (title_score, search_score) {
        (Some(title), Some(search)) => Some(
            f64::from(search)
                .max(f64::from(title) + 2_000.0)
                .max(exact_search_text_score.unwrap_or(f64::NEG_INFINITY))
                .max(initialism_score.unwrap_or(f64::NEG_INFINITY)),
        ),
        (Some(title), None) => Some(
            (f64::from(title) + 2_000.0)
                .max(exact_search_text_score.unwrap_or(f64::NEG_INFINITY))
                .max(initialism_score.unwrap_or(f64::NEG_INFINITY)),
        ),
        (None, Some(search)) => Some(
            f64::from(search)
                .max(exact_search_text_score.unwrap_or(f64::NEG_INFINITY))
                .max(initialism_score.unwrap_or(f64::NEG_INFINITY)),
        ),
        (None, None) => exact_search_text_score.or(initialism_score),
    }
}

fn exact_search_text_line_score(candidate: &Candidate, query: &str) -> Option<f64> {
    if query.is_empty() {
        return None;
    }

    let query_char_count = query.chars().count();
    let mut keyword_exact_score = None;
    for line in candidate.search_text.lines() {
        let trimmed = line.trim();
        if !trimmed.eq_ignore_ascii_case(query) {
            continue;
        }
        if trimmed.eq_ignore_ascii_case(candidate.title.trim()) {
            return Some(30_000.0 + f64::from(query_char_count as u32) * 10.0);
        }
        keyword_exact_score = Some(keyword_exact_line_score(query_char_count));
    }
    keyword_exact_score
}

fn keyword_exact_line_score(query_char_count: usize) -> f64 {
    if query_char_count <= 3 {
        return 30_000.0 + f64::from(query_char_count as u32) * 10.0;
    }
    1_800.0 + f64::from(query_char_count as u32) * 10.0
}

fn title_phrase_score(
    candidate: &Candidate,
    query_lowercase: &str,
    query_token_count: usize,
) -> Option<f64> {
    if query_lowercase.is_empty() {
        return None;
    }

    let title = &candidate.title_lowercase;
    let Some(start_byte) = title.find(query_lowercase) else {
        return None;
    };
    let end_byte = start_byte + query_lowercase.len();
    let query_char_count = query_lowercase.chars().count();
    let query_token_count = query_token_count.max(1);

    if title == query_lowercase {
        return Some(
            80_000.0 * query_token_count as f64 + f64::from(query_char_count as u32) * 20.0,
        );
    }

    let starts_on_boundary = start_byte == 0
        || title[..start_byte]
            .chars()
            .last()
            .is_some_and(is_title_word_boundary);
    let ends_on_boundary = end_byte == title.len()
        || title[end_byte..]
            .chars()
            .next()
            .is_some_and(is_title_word_boundary);
    if !starts_on_boundary || !ends_on_boundary {
        return None;
    }

    let trailing_penalty = candidate.title_char_count.saturating_sub(query_char_count) as f64 * 6.0;
    if start_byte == 0 {
        return Some(
            70_000.0 * query_token_count as f64 + f64::from(query_char_count as u32) * 20.0
                - trailing_penalty,
        );
    }

    let start_char_count = title[..start_byte].chars().count();
    Some(
        60_000.0 * query_token_count as f64 + f64::from(query_char_count as u32) * 20.0
            - start_char_count as f64 * 30.0
            - trailing_penalty,
    )
}

fn initialism_query(query: &str) -> Option<InitialismQuery> {
    if query.bytes().any(|byte| byte.is_ascii_whitespace()) {
        return None;
    }

    let query_chars: Vec<char> = query.chars().flat_map(char::to_lowercase).collect();
    if !(2..=8).contains(&query_chars.len()) || query_chars.iter().any(|c| !c.is_alphanumeric()) {
        return None;
    }

    Some(InitialismQuery { chars: query_chars })
}

fn title_initialism_score(query: &InitialismQuery, candidate: &Candidate) -> Option<f64> {
    let title_initials = &candidate.title_initials;
    if query.chars.len() > title_initials.len() {
        return None;
    }

    let mut next_word_index = 0;
    let mut first_word: Option<usize> = None;
    let mut last_word = 0;
    let mut matched_count = 0;

    for query_char in &query.chars {
        let mut found_word_index = None;
        while next_word_index < title_initials.len() {
            let word_index = next_word_index;
            let word_char = title_initials[next_word_index];
            next_word_index += 1;
            if word_char == *query_char {
                found_word_index = Some(word_index);
                break;
            }
        }
        let word_index = found_word_index?;
        first_word = first_word.or(Some(word_index));
        last_word = word_index;
        matched_count += 1;
    }

    let first_word = first_word.unwrap_or(0);
    let skipped_before = first_word;
    let skipped_between = last_word + 1 - matched_count - first_word;
    let skipped_after = title_initials.len().saturating_sub(last_word + 1);
    let exact_word_count_bonus = if query.chars.len() == title_initials.len() {
        1_200.0
    } else {
        0.0
    };

    Some(
        14_000.0 + f64::from(query.chars.len() as u32) * 420.0 + exact_word_count_bonus
            - f64::from(skipped_before as u32) * 260.0
            - f64::from(skipped_between as u32) * 180.0
            - f64::from(skipped_after as u32) * 80.0
            - f64::from(candidate.title_char_count as u32) * 2.0,
    )
}

fn title_word_initials(title: &str) -> Vec<char> {
    let mut starts = Vec::new();
    let mut previous_was_boundary = true;
    for character in title.chars() {
        let is_boundary = is_title_word_boundary(character);
        if !is_boundary && previous_was_boundary {
            if let Some(lowercase) = character.to_lowercase().next() {
                starts.push(lowercase);
            }
        }
        previous_was_boundary = is_boundary;
    }
    starts
}

fn is_title_word_boundary(character: char) -> bool {
    matches!(character, ' ' | '-' | '_' | '/' | '\\' | '.' | ':')
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

#[cfg(test)]
mod tests {
    use super::*;

    fn test_candidate(title: &str, search_lines: &[&str], rank: i32) -> Candidate {
        let search_text = search_lines.join("\n");
        let ascii_prefilter_safe = title.is_ascii() && search_text.is_ascii();
        let (title_low, title_high) = ascii_mask(title);
        let (search_low, search_high) = ascii_mask(&search_text);
        Candidate {
            title: title.to_owned(),
            title_lowercase: title.to_lowercase(),
            search_text: search_text.clone(),
            search_lines: search_text.lines().map(str::to_owned).collect(),
            rank,
            ascii_prefilter_safe,
            ascii_mask_low: title_low | search_low,
            ascii_mask_high: title_high | search_high,
            title_initials: title_word_initials(title),
            title_char_count: title.chars().count(),
        }
    }

    fn search_candidate_indices(
        candidates: Vec<Candidate>,
        query: &str,
        limit: usize,
        boosts: Option<&[i32]>,
    ) -> Vec<usize> {
        let mut index = CmuxNucleoIndex { candidates };
        let mut matches = vec![
            CmuxNucleoMatch {
                index: 0,
                score: 0.0,
                rank: 0,
            };
            limit
        ];
        let mut out_count = 0;

        let status = unsafe {
            cmux_nucleo_index_search_impl(
                &mut index,
                query.as_ptr(),
                query.len(),
                limit,
                boosts
                    .map(|values| values.as_ptr())
                    .unwrap_or(std::ptr::null()),
                boosts.map(|values| values.len()).unwrap_or(0),
                matches.as_mut_ptr(),
                matches.len(),
                &mut out_count,
            )
        };

        assert_eq!(status, 0);
        matches.truncate(out_count);
        matches.into_iter().map(|result| result.index).collect()
    }

    #[test]
    fn title_phrase_prefix_beats_description_phrase_match() {
        let matches = search_candidate_indices(
            vec![
                test_candidate(
                    "owl browser engine",
                    &[
                        "owl browser engine",
                        "Workspace",
                        "workspace",
                        "switch",
                        "go",
                        "open",
                        "Use Owl 2 pieces that are ready: generated Mojo transports, Swift-owned pipe handles, and resize verification gates.",
                        "owl",
                        "2",
                    ],
                    0,
                ),
                test_candidate(
                    "owl 2 aws",
                    &["owl 2 aws", "Workspace", "workspace", "switch", "go", "open"],
                    6,
                ),
            ],
            "owl 2",
            5,
            None,
        );

        assert_eq!(matches.first(), Some(&1));
    }
}
