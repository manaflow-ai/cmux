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

function piSidebarTargetArgs(dispatcher: PiCmuxCommandDispatcher, sessionId: string): string[] | null {
  const target = surfaceTargetArgs(dispatcher, sessionId);
  if (!target) return null;
  return target.map((value) => value === "--surface" ? "--panel" : value);
}

function piQuestionLike(value: string | undefined): boolean {
  if (!value) return false;
  return /[?？]\s*$/.test(value.trim());
}

async function publishPiWorkspaceMetadata(
  dispatcher: PiCmuxCommandDispatcher,
  context: PiExtensionContextSnapshot,
  sessionId: string,
): Promise<void> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  const target = piSidebarTargetArgs(dispatcher, sessionId);
  if (!target) return;

  await dispatcher.run(
    ["report_pwd", context.cwd, `--path=${context.cwd}`, ...target],
    context.cwd,
    undefined,
    context,
  );
  const branch = await runPiGitCommand(context.cwd, ["branch", "--show-current"]);
  if (!branch) {
    await dispatcher.run(
      ["clear_git_branch", ...target],
      context.cwd,
      undefined,
      context,
    );
    return;
  }
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
  const target = piSidebarTargetArgs(dispatcher, sessionId);
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
  context: PiExtensionContextSnapshot,
  turnId: string,
): Promise<void> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  const sessionId = context.sessionId;
  if (!sessionId) return;
  await sendHook(dispatcher, "notification", context, {
    hook_event_name: "questionAsked",
    event: "questionAsked",
    // Keep Pi's prompt text inside Pi. cmux needs only the semantic wait
    // signal; the host localizes the notification body.
    message: "needs_input",
    notification: { type: "question" },
    turn_id: turnId,
  });
}

async function publishPiApprovalResponse(
  dispatcher: PiCmuxCommandDispatcher,
  context: PiExtensionContextSnapshot,
  turnId: string,
  idleDialog: boolean,
): Promise<void> {
  if (process.env.CMUX_PI_HOOKS_DISABLED === "1") return;
  const sessionId = context.sessionId;
  if (!sessionId) return;
  await sendHook(dispatcher, "approval-response", context, {
    turn_id: turnId,
    cmux_pi_idle_dialog: idleDialog,
  });
}

interface PiUIDialogLifecycle {
  turnId: string;
  resolveTurn: boolean;
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
  const signal = (_message: string): PiUIDialogLifecycle | undefined => {
    const current = snapshot();
    const sessionId = current.sessionId;
    if (!sessionId) return undefined;
    const state = stateFor(sessionStates, sessionId);
    const activeTurnId = state.activeTurnId;
    const turnId = activeTurnId || randomUUID();
    void enqueueLifecycleTask(sessionId, current, () => publishPiQuestion(
      dispatcher,
      current,
      turnId,
    ));
    return { turnId, resolveTurn: activeTurnId !== undefined };
  };
  const resolved = (dialog: PiUIDialogLifecycle | undefined) => {
    const current = snapshot();
    const sessionId = current.sessionId;
    if (!sessionId || !dialog) return;
    void enqueueLifecycleTask(sessionId, current, () => publishPiApprovalResponse(
      dispatcher,
      current,
      dialog.turnId,
      !dialog.resolveTurn,
    ));
  };

  ui.confirm = (title: string, message: string, options?: unknown) => {
    const dialog = signal([title, message].filter(Boolean).join(": "));
    return Promise.resolve(originalConfirm(title, message, options)).finally(() => {
      resolved(dialog);
    });
  };
  ui.select = (title: string, options: string[], dialogOptions?: unknown) => {
    const dialog = signal([title, ...(options || []).slice(0, 4)].filter(Boolean).join(" — "));
    return Promise.resolve(originalSelect(title, options, dialogOptions)).finally(() => {
      resolved(dialog);
    });
  };
  ui.input = (title: string, placeholder?: string, options?: unknown) => {
    const dialog = signal([title, placeholder].filter(Boolean).join(": "));
    return Promise.resolve(originalInput(title, placeholder, options)).finally(() => {
      resolved(dialog);
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
