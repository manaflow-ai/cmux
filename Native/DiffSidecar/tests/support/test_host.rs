fn main() {
    let arguments = std::env::args().collect::<Vec<_>>();
    let command = arguments.get(1).map(String::as_str).unwrap_or_default();
    match command {
        "__diff-viewer-refs"
            if arguments
                .iter()
                .any(|argument| argument == "--suggested-only") =>
        {
            println!(
                r#"{{"groups":[{{"id":"suggested","label":"Suggested","rows":[{{"ref":"HEAD","label":"HEAD","current":true}}]}}]}}"#
            );
        }
        // Deliberately exceeds the sidecar's bounded smart-base response. The
        // branch-session integration test fails if it regresses to requesting
        // the complete picker payload for initial base resolution.
        "__diff-viewer-refs" => println!(
            "{{\"groups\":[{{\"id\":\"suggested\",\"label\":\"Suggested\",\"rows\":[{{\"ref\":\"HEAD\",\"label\":\"HEAD\"}}]}},{{\"id\":\"branches\",\"label\":\"Branches\",\"rows\":[{{\"ref\":\"{}\",\"label\":\"oversized\"}}]}}]}}",
            "x".repeat(8192)
        ),
        "__diff-viewer-branch" => {
            let base = arguments
                .windows(2)
                .find_map(|pair| (pair[0] == "--base").then_some(pair[1].as_str()));
            if base == Some("malformed") {
                println!("cmux-diff-viewer://0123456789abcdef/../not-allowed.html");
            } else {
                println!("cmux-diff-viewer://0123456789abcdef/generated.html");
            }
        }
        _ => std::process::exit(2),
    }
}
