# Late exact-SHA CI audit

PR source HEAD: `e20d1138de38c3f9c4041b53ec89862108d556f7`.

Earlier exact-SHA focused runs were green, including:

- `SurfaceResumeExitedAgentLivenessTests`: run 29873523759, success
- `AgentHibernationTests`: run 29873523779, success
- `RestorableAgentProcessGenerationTests`: run 29873524269, success
- `SurfaceResumeAgentBindingGenerationTests`: run 29873525070, success
- `RestorableAgentSessionStalePIDTests`: run 29873525325, success

Two later dispatches were red at evidence-capture time:

1. Run 29877596324 (`CmuxWorkspacesTests/RestorableAgentProcessLivenessTests`) selected the `cmuxUITests` target and executed 0 tests. The workflow itself rejected the zero-test result. This is a filter/target error, not a behavioral test failure.
2. Run 29877596247 (`AgentSessionAutoResumeSettingsTests`) executed 14 tests with 2 failures:
   - line 559: `testAgentHookResumeBindingClearsAfterStartupCommandCompletes` failed because `XCTUnwrap` received nil;
   - line 252: `testRemoteWorkspaceAutoResumeKeepsRemoteStartupCommand` expected nil but received `/Users/runner`.

These late results must be triaged or rerun before claiming an all-green/100%-confidence closeout, even though the issue-specific focused suite and runtime stale trial passed.
