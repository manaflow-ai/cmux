# Runtime interaction evidence

Captured 2026-07-21 on the isolated tagged app only.

## Build identity

- PR source HEAD: `e20d1138de38c3f9c4041b53ec89862108d556f7`
- Tagged app: `issue-8423-resume-exited-agent-cwd-picker`
- Bundle ID: `com.cmuxterm.app.debug.issue.8423.resume.exited.agent.cwd.picker`
- Socket: `/tmp/cmux-debug-issue-8423-resume-exited-agent-cwd-picker.sock`
- Cloud build run: `29875892035` (`success`)
- Cloud wrapper commit: `d43ba10ee2ef576adef4b3eada9c9df2506b4d70`; source code matches PR HEAD, with only the provisioning-blocker artifact added by the wrapper.
- App path: `/Users/austinwang/Library/Developer/Xcode/DerivedData/cmux-issue-8423-resume-exited-agent-cwd-picker/Build/Products/Debug/cmux DEV issue-8423-resume-exited-agent-cwd-picker.app`

## Exact stale-agent trial

1. Created workspace `issue8423-acceptance-233422` with `--focus false` in the unique cwd `.../interaction/codex-cwd`; immediately set its status override to `none`.
2. Original workspace UUID: `5C2E53C7-7C16-4FB7-BE20-5CF77032AEA7`.
3. Terminal surface UUID: `72A1732A-8B11-491C-8634-54133C9E25E5`.
4. Launched real `codex-cli 0.144.6` interactively with `-a never`, the unique cwd, and `--no-alt-screen`.
5. Codex returned `SESSION_READY_8423`.
6. Surface binding and the sanitized hook-record projection agreed on:
   - session: `019f8708-8b6a-7613-9aa0-0dacca34af3c`
   - workspace/surface UUIDs above
   - unique cwd above
   - recorded PID: `59174`
   - recorded PID start identity: `1784676910.017370`
   - resume argument count: 6
7. Submitted `/exit`. Codex printed its normal token-usage and `To continue this session, run codex resume ...` footer, returned to the shell prompt, and PID 59174 became absent. The hook record and resume binding still existed at shutdown.
8. Gracefully quit the tagged bundle through Apple Events and relaunched the exact tagged app. PID changed from 26711 to 84294.
9. After restore:
   - the exact surface UUID `72A1732A-8B11-491C-8634-54133C9E25E5` remained;
   - the workspace object was reconstructed as UUID `991F390A-B7D6-4CF5-B130-6AC04D17F224`;
   - the same Codex session binding, cwd, source `agent-hook`, `auto_resume=true`, and `-a never` command metadata remained;
   - app descendant scan found 0 commands containing the session ID plus `resume`;
   - app descendant scan found 0 `/tmp/cmux-surface-resume` launchers;
   - restored scrollback was readable (331 bytes), with 0 `Choose working directory to resume this session` matches and 0 `codex resume <session-id>` invocations;
   - the shell printed `RESTORE1_SHELL_OK_8423` and returned to its prompt in the expected cwd.
10. DEBUG decision lines for the preserved surface were:
    - `session.restore.agent ... kind=codex session=019f8708 hasLaunch=1 launchArgc=6 hasResume=0 autoResume=1 replayScrollback=0`
    - `session.restore.surfaceResume ... kind=codex source=agent-hook hasLaunch=0 replayScrollback=0`

The `hasLaunch=1` field describes saved launch metadata on the restorable-agent snapshot. The two authoritative execution decisions are `hasResume=0` and surface-resume `hasLaunch=0`, matching the zero-child process scan.

## Additional restart controls

- After the first restore sentinel completed, DEBUG logged `session.restore.agent.invalidate` and the binding became null. This is expected completed-generation cleanup.
- A second graceful app restart succeeded (PID 84294 to 13887). The exact surface UUID and cwd persisted, while process scans again found 0 Codex-resume and 0 launcher descendants. It was a shell-only negative control because the first sentinel had already invalidated the stale binding.
- Two more real Codex sessions were run and exited normally, including one in a second brand-new workspace (`issue8423-acceptance2-2345`, `--focus false`, status `none`). On the current fixed runtime their bindings were naturally cleared within seconds of clean `/exit`. No CLI binding was injected to manufacture another stale state.
- Because the runtime itself prevented a second naturally stale binding, only the first restart is an exact end-to-end stale-metadata trial. Repeated state-machine cases remain covered by the focused automated suite; a second natural stale-metadata restart is an explicit evidence gap, not a claimed pass.

## Acceptance results

| Criterion | Result | Evidence |
|---|---|---|
| Unique workspace, no focus, status none | PASS | Workspace and status operations above |
| Real Codex `-a never`, known cwd, binding/record/PID identity, clean exit | PASS | Session `019f...af3c`, PID/start identity, normal `/exit` footer |
| First exact stale restore: metadata retained, no relaunch/picker, responsive shell | PASS | Stable surface, same binding, zero child/launcher/picker counts, sentinel, DEBUG `hasResume=0`/`hasLaunch=0` |
| Two graceful tagged app restarts | PASS as process/shell controls | PID transitions 26711 -> 84294 -> 13887; no resume descendants on either |
| Same stale metadata across both restarts | NOT PROVEN | First sentinel intentionally invalidated the generation; later clean exits naturally cleared bindings |
| Exact live-generation auto-resume runtime trial | NOT RUN | Avoided overwriting the completed stale evidence; automated exact-PID test is the available proof |
| Production cmux isolation | PASS | Every operation used the tag-bound helper and tagged bundle/socket |

No raw hook store, tokens, transcript, or complete user configuration is included in this artifact.
