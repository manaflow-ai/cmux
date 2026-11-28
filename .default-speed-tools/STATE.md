# Default-grid detector execution state

Repo manaflow-ai/cmux; draft https://github.com/manaflow-ai/cmux/pull/63738.
Worktree /mnt/lane-data/checkouts/cmux/lane--phone-default-speed.
Local head 19834f1bd501f32e380edd7109422ab3d7206b21 integrates projection f986535a6442599ed78eb2129a61c101852b27dd/base a49ff296.
Published head 19834f1bd501f32e380edd7109422ab3d7206b21; exec31336 exited0 at02:09Z and cmux-ci branch-tip guard confirmed exact remote head.

Focused source review PASS at 19834. Integration routing: 17 tests / 51.303s, cleanup: 1 / 3.321s (integrated-routing.log and integrated-timeout.log). Linux ceiling computed 692 minutes; existing web-typecheck land gate preserved. Stop confirmation + pidfd exit wait, pinned real Cargo cold invocation, seed setup budget and FAST_CHECKS_OUT output are implemented.

Current publication retry: exec session31336, PID3496031, integrated-push-retry.log. Original integrated bg push ended without publication; previous queued study correctly refused old remote head and ran nothing.
One replacement study queue: exec session1950, managed-study-retry.log. It waits PID3496031 then runs cmux-ci test --route fleet --setup none --at 19834f1bd501f32e380edd7109422ab3d7206b21 --timeout5400 --artifact /tmp/phone-default-speed-receipt -- python3 scripts/bench/phone-default-speed/study.py. Do not start a duplicate job. Exact remote-head gate must accept before native work runs.

No native baseline, actual fixture, cold/warm cost or native mutation proof yet. No device calibration and no hardware-flow-complete claim. Keep draft, do not merge.

Cache proof gap: current study bypasses restore and uses fresh .build/PID target. Production helper only operates in Actions/default target and keys absolute source path. Above14GiB, production stripping removes ghostty-vt-sys and omits source mtime manifest. A cache key hit or same-job Fresh does not establish native survival/reuse. After first native numbers, use two isolated producer/consumer jobs with identical source/tool/target paths and actual post-prune archive plus source mtime manifest; check first consumer Fresh and unchanged native hashes. This proves archive portability only. Trusted production R2 save/selector still needs separate postmerge proof; do not spoof push/ref or write global cache keys.

Parent /root/speed_mock owns projection #63285 and knows current limitations. Root updated #63738 title/body, draft unchanged, after lease refusal. Current owner remains /root/speed_mock/default_speed for study and final loop.

2026-11-28 02:15Z resume: exec1950 / process3506325 (cmux-ci3506341) still preparing source, current child git pack-objects. Request key lane-test-manaflow-ai-cmux-19834f1bd501-2fef1341. No fleet job acceptance yet. Do not duplicate dispatch. Reviewer says minimum post-study retention fix is cmux-tui-test-target.sh save --keep ghostty-vt-sys and unconditional source-mtime recording after pruning; existing keep supported. Native study head held fixed.
