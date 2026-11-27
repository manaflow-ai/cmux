use super::is_work_narration;
#[test]
fn narration_is_a_short_progress_note_and_anything_else_is_an_answer() {
    for (text, narration) in [
        ("Let me check the cache.", true),
        ("Reading `client.ts` next.", true),
        ("I'm running the tests", true),
        ("I’ll look at the logs. Checking CI.", true),
        ("Both checks are still running", true),
        ("Checking the failed jobs.", true),
        ("Waiting for the build...", true),
        ("Let me check. The cache is stale.", false),
        ("Let me check; the cache is stale", false),
        ("Running two tasks is faster", false),
        ("Checking the cache found no errors.", false),
        ("Checking the cache returned nothing.", false),
        ("Checking the jobs failed twice.", false),
        ("Let me check. Reading it. Testing it.", false),
        ("Done.", false),
        ("Checkingly odd.", false),
        ("Let me checks", false),
        ("Reading the feed now", true),
    ] {
        assert_eq!(is_work_narration(text), narration, "{text:?}");
    }
}
