extension CMUXCLI {
    static let piExtensionSourceMetadata = #"""
function runPiGitCommand(cwd: string, args: string[]): Promise<string | null> {
  return new Promise((resolve) => {
    const child = spawn("git", ["-C", cwd, ...args], {
      cwd,
      env: hookEnvironment(cwd),
      stdio: ["ignore", "pipe", "ignore"],
    });
    let output = "";
    child.stdout?.on("data", (chunk: Buffer | string) => {
      if (output.length < 4096) output += String(chunk).slice(0, 4096 - output.length);
    });
    child.on("error", () => resolve(null));
    child.on("close", (status) => resolve(status === 0 ? output.trim() || null : null));
  });
}

function piToolCommand(event: unknown): string | null {
  const args = objectValue(event, ["args", "input"]);
  return firstString(
    objectValue(event, ["command", "cmd"]),
    objectValue(args, ["command", "cmd"]),
  );
}

function piPullRequestAction(command: string): string | null {
  const match = /\bgh\s+pr\s+(create|merge|close|reopen|ready|edit|view|checkout)\b/i.exec(command);
  return match?.[1]?.toLowerCase() || null;
}

function piGitMetadataCommand(command: string): boolean {
  return /\b(?:git\s+(?:checkout|switch|branch|commit|pull|rebase|reset)|gh\s+pr\s+)/i.test(command);
}

function piQuestionLike(value: string | undefined): boolean {
  if (!value) return false;
  return /\?\s*$/.test(value.trim())
    || /\b(?:which|what|where|when|how|whether)\b.*\b(?:choose|use|select|prefer|take)\b/i.test(value);
}

async function publishPiWorkspaceMetadata(
  dispatcher: PiCmuxCommandDispatcher,
  context: PiExtensionContextSnapshot,
  sessionId: string,
): Promise<void> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  const target = surfaceTargetArgs(dispatcher, sessionId);
  if (!target) return;

  await dispatcher.run(
    ["report_pwd", context.cwd, `--path=${context.cwd}`, ...target],
    context.cwd,
    undefined,
    context,
  );
  const branch = await runPiGitCommand(context.cwd, ["branch", "--show-current"]);
  if (!branch) return;
  await dispatcher.run(
    ["report_git_branch", branch, "--status=unknown", ...target],
    context.cwd,
    undefined,
    context,
  );
}

async function publishPiPullRequestHint(
  dispatcher: PiCmuxCommandDispatcher,
  context: PiExtensionContextSnapshot,
  sessionId: string,
  action: string,
): Promise<void> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  const target = surfaceTargetArgs(dispatcher, sessionId);
  if (!target) return;
  await dispatcher.run(
    ["report_pr_action", action, ...target],
    context.cwd,
    undefined,
    context,
  );
}

async function publishPiQuestion(
  dispatcher: PiCmuxCommandDispatcher,
  sessionStates: Map<string, SessionState>,
  context: PiExtensionContextSnapshot,
  message: string,
): Promise<void> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  const sessionId = context.sessionId;
  if (!sessionId) return;
  await sendHook(dispatcher, "notification", context, {
    hook_event_name: "questionAsked",
    event: "questionAsked",
    message: utf8Prefix(message, 512) || "Pi is waiting for input",
    notification: { type: "question" },
    turn_id: currentTurnId(sessionStates, sessionId, {}),
  });
}

async function publishPiApprovalResponse(
  dispatcher: PiCmuxCommandDispatcher,
  sessionStates: Map<string, SessionState>,
  context: PiExtensionContextSnapshot,
): Promise<void> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  const sessionId = context.sessionId;
  if (!sessionId) return;
  await sendHook(dispatcher, "approval-response", context, {
    turn_id: currentTurnId(sessionStates, sessionId, {}),
  });
}

function installPiUIDialogHooks(
  dispatcher: PiCmuxCommandDispatcher,
  sessionStates: Map<string, SessionState>,
  context: ExtensionContext,
  enqueueLifecycleTask: (
    sessionId: string,
    context: PiExtensionContextSnapshot,
    operation: () => Promise<unknown> | unknown,
  ) => Promise<void>,
): (() => void) | undefined {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1" || !context.hasUI) return undefined;
  const ui = context.ui as any;
  const patchKey = Symbol.for("cmux.pi.cmux-dialog-hooks");
  if (ui[patchKey]) return undefined;

  const originalConfirm = ui.confirm.bind(ui);
  const originalSelect = ui.select.bind(ui);
  const originalInput = ui.input.bind(ui);
  const snapshot = () => snapshotContext(context);
  const signal = (message: string) => {
    const current = snapshot();
    const sessionId = current.sessionId;
    if (!sessionId) return;
    void enqueueLifecycleTask(sessionId, current, () => publishPiQuestion(
      dispatcher,
      sessionStates,
      current,
      message,
    ));
  };
  const resolved = () => {
    const current = snapshot();
    const sessionId = current.sessionId;
    if (!sessionId) return;
    void enqueueLifecycleTask(sessionId, current, () => publishPiApprovalResponse(
      dispatcher,
      sessionStates,
      current,
    ));
  };

  ui.confirm = (title: string, message: string, options?: unknown) => {
    signal([title, message].filter(Boolean).join(": "));
    return originalConfirm(title, message, options).then((value: boolean) => {
      resolved();
      return value;
    });
  };
  ui.select = (title: string, options: string[], dialogOptions?: unknown) => {
    signal([title, ...(options || []).slice(0, 4)].filter(Boolean).join(" — "));
    return originalSelect(title, options, dialogOptions).then((value: string | undefined) => {
      resolved();
      return value;
    });
  };
  ui.input = (title: string, placeholder?: string, options?: unknown) => {
    signal([title, placeholder].filter(Boolean).join(": "));
    return originalInput(title, placeholder, options).then((value: string | undefined) => {
      resolved();
      return value;
    });
  };
  ui[patchKey] = true;

  return () => {
    ui.confirm = originalConfirm;
    ui.select = originalSelect;
    ui.input = originalInput;
    delete ui[patchKey];
  };
}
"""#
}
