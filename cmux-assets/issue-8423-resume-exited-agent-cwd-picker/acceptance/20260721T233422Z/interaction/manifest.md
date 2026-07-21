# Interaction evidence manifest

Generated: `2026-07-21T23:49:00Z`

Build identity:

- PR: https://github.com/manaflow-ai/cmux/pull/8547
- PR HEAD: `e20d1138de38c3f9c4041b53ec89862108d556f7`
- Cloud build run: https://github.com/manaflow-ai/cmux/actions/runs/29875892035
- Tagged app: `issue-8423-resume-exited-agent-cwd-picker`
- Bundle: `com.cmuxterm.app.debug.issue.8423.resume.exited.agent.cwd.picker`
- Socket: `/tmp/cmux-debug-issue-8423-resume-exited-agent-cwd-picker.sock`

Artifacts:

- `runtime-evidence.md` — sanitized real-Codex stale restore, restart controls, process/picker/sentinel results, and criterion verdicts
- `memory-profile.md` — tagged app RSS/CPU samples, final descendant tree summary, compiler counts, swap and compression
- `cua-blocker.md` — exact doctor, full-screen recording, and screenshot permission blockers
- `late-ci-audit.md` — exact-SHA green focused matrix plus two later red dispatches requiring triage

Sanitization:

- No raw hook store or complete transcript is copied.
- No prompt history beyond test-only sentinels is stored.
- No token, credential, environment dump, auth file, or full cmux configuration is stored.
- Session, workspace, surface, PID, cwd, and start-identity fields are retained because they are the acceptance evidence.

Interaction/profiling role: `/root/runtime_interaction_8423`.

This role does not self-approve. Final artifact verification remains the orchestrator's responsibility.
