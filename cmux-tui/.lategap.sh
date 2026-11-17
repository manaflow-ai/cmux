#!/bin/bash
cd cmux-tui
cargo test -p cmux-rd-core --test media a_gap_exposed_after 2>&1 | grep -E "^test |test result|panicked|late gap|error" | head
