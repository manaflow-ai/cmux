extension CMUXCLI {
    static let ampExtensionReconciliation = #"""
export default function (amp: PluginAPI) {
  const rootThread = (amp as unknown as { thread?: AmpThread }).thread;
  const helpers = (amp as unknown as { helpers?: unknown }).helpers;
  const cwdFromEnv = (): string => firstString(process.env.PWD, process.cwd()) || process.cwd();
  const titleByThread = new Map<string, string>();
  const titleVersions = new Map<string, number>();
  const titleLookupTokens = new Map<string, number>();
  const observedTitleThreads = new Set<string>();
  const titleSubscriptions = new Map<string, { unsubscribe?: () => void; flush?: () => void }>();
  const stateSubscriptions = new Map<string, { unsubscribe?: () => void }>();
  const threadById = new Map<string, AmpThread>();
  type AmpThreadLifecycle = {
    authoritativeState: string;
    observationVersion: number;
    turnStateStartVersion: number;
    inFlightTools: number;
    presentation: AmpStatusPresentation;
    pendingTurn: {
      outcome: string;
      turnId: string | null;
      assistantMessage: string | null;
    } | null;
    terminalEventEmitted: boolean;
    activeTurnId: string | null;
  };
  const lifecycleByThread = new Map<string, AmpThreadLifecycle>();
  const activeThread = (amp as unknown as {
    activeThread?: AmpActiveThreadObservable;
  }).activeThread;
  const threads = (amp as unknown as { threads?: AmpThreads }).threads;
  let presentedThreadId = firstString(activeThread?.current?.id);
  const TITLE_MAX_LENGTH = 200;
  const TITLE_DEBOUNCE_MS = 100;
  const LOOKUP_TIMEOUT_MS = 1000;

  function threadFrom(event: { thread?: AmpThread } | undefined, ctx?: AmpThreadContext): AmpThread | undefined {
    const thread = ctx?.thread || event?.thread || rootThread;
    const threadId = firstString(thread?.id);
    if (thread && threadId) threadById.set(threadId, thread);
    return thread;
  }

  function threadIdFrom(event: { thread?: AmpThread } | undefined, ctx?: AmpThreadContext): string | null {
    return firstString(event?.thread?.id, ctx?.thread?.id, rootThread?.id);
  }

  function lifecycleFor(threadId: string): AmpThreadLifecycle {
    const existing = lifecycleByThread.get(threadId);
    if (existing) return existing;
    const created: AmpThreadLifecycle = {
      authoritativeState: "idle",
      observationVersion: 0,
      turnStateStartVersion: 0,
      inFlightTools: 0,
      presentation: PRESENTATION.idle,
      pendingTurn: null,
      terminalEventEmitted: false,
      activeTurnId: null,
    };
    lifecycleByThread.set(threadId, created);
    return created;
  }

  function isPresentedThread(threadId: string): boolean {
    return activeThread ? presentedThreadId === threadId : true;
  }

  function projectThreadPresentation(threadId: string): void {
    if (!isPresentedThread(threadId)) return;
    const presentation = lifecycleFor(threadId).presentation;
    setStatus(presentation.label, presentation.icon, presentation.color);
  }

  function updateThreadPresentation(
    threadId: string,
    presentation: AmpStatusPresentation,
  ): void {
    lifecycleFor(threadId).presentation = presentation;
    projectThreadPresentation(threadId);
  }

  function normalizedTurnId(value: unknown): string | null {
    if (typeof value === "number" && Number.isFinite(value)) return String(value);
    return firstString(value);
  }

  function lastAssistantMessage(event: AgentEndEvent): string | null {
    const messages = Array.isArray(event.messages) ? event.messages : [];
    for (let index = messages.length - 1; index >= 0; index -= 1) {
      const message = messages[index] as {
        role?: unknown;
        content?: Array<{ type?: unknown; text?: unknown }>;
      };
      if (message.role !== "assistant" || !Array.isArray(message.content)) continue;
      const text = message.content
        .filter((block) => block?.type === "text" && typeof block.text === "string")
        .map((block) => String(block.text))
        .join("\n")
        .trim();
      if (text) return text.slice(0, 1000);
    }
    return null;
  }

  function turnPayload(
    lifecycle: AmpThreadLifecycle,
    pending = lifecycle.pendingTurn,
  ): Record<string, unknown> {
    const turnId = pending?.turnId || lifecycle.activeTurnId;
    const assistantMessage = pending?.assistantMessage;
    return {
      ...(turnId ? { turn_id: turnId } : {}),
      ...(assistantMessage ? { last_assistant_message: assistantMessage } : {}),
    };
  }

  function normalizedTitle(value: unknown): string | null {
    const raw = typeof value === "string"
      ? value
      : firstString((value as { value?: unknown } | null)?.value);
    if (!raw) return null;
    const title = raw.slice(0, TITLE_MAX_LENGTH * 2).replace(/\s+/g, " ").trim();
    if (!title) return null;
    return title.length > TITLE_MAX_LENGTH ? title.slice(0, TITLE_MAX_LENGTH - 1) + "…" : title;
  }

  function titleExtra(threadId: string): Record<string, unknown> {
    const title = titleByThread.get(threadId);
    return title ? { title } : {};
  }

  function rememberTitle(threadId: string, value: unknown): string | null {
    const title = normalizedTitle(value);
    if (!title) return null;
    if (titleByThread.get(threadId) === title) return title;
    titleByThread.set(threadId, title);
    titleVersions.set(threadId, (titleVersions.get(threadId) || 0) + 1);
    return title;
  }

  function beginTitleLookup(threadId: string): number {
    const token = (titleLookupTokens.get(threadId) || 0) + 1;
    titleLookupTokens.set(threadId, token);
    return token;
  }

  function fallbackTitleFromAgentStart(event: AgentStartEvent): string | null {
    return normalizedTitle((event as unknown as { message?: unknown }).message);
  }

  async function withLookupTimeout(value: Promise<unknown> | unknown): Promise<unknown> {
    return await Promise.race([
      Promise.resolve(value),
      new Promise<null>((resolve) => setTimeout(() => resolve(null), LOOKUP_TIMEOUT_MS)),
    ]);
  }

  function resolveThreadTitle(threadId: string, thread?: AmpThread): void {
    if (!thread?.title?.get) return;
    const token = beginTitleLookup(threadId);
    const startVersion = titleVersions.get(threadId) || 0;
    let lookup: Promise<unknown> | unknown;
    try {
      lookup = thread.title.get();
    } catch (_) {
      return;
    }
    void withLookupTimeout(lookup)
      .then((value) => {
        if (titleLookupTokens.get(threadId) !== token) return;
        if ((titleVersions.get(threadId) || 0) !== startVersion) return;
        const candidate = normalizedTitle(value);
        if (!candidate) return;
        if (observedTitleThreads.has(threadId) && titleByThread.get(threadId) !== candidate) return;
        const title = rememberTitle(threadId, candidate);
        if (title) sendHook("title-update", threadId, cwdFromEnv(), { title });
      })
      .catch(() => {});
  }

  function watchThreadTitle(threadId: string, thread?: AmpThread): void {
    const observable = thread?.title;
    if (!observable?.subscribe || titleSubscriptions.has(threadId)) return;
    let pendingTitle: string | null = null;
    let lastSent: string | null = null;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const flush = () => {
      if (timer !== null) clearTimeout(timer);
      timer = null;
      const title = pendingTitle;
      pendingTitle = null;
      if (!title || title === lastSent) return;
      lastSent = title;
      titleByThread.set(threadId, title);
      sendHook("title-update", threadId, cwdFromEnv(), { title });
    };
    try {
      const subscription = observable.subscribe((value) => {
        const title = rememberTitle(threadId, value);
        if (!title || title === lastSent) return;
        observedTitleThreads.add(threadId);
        pendingTitle = title;
        if (timer !== null) clearTimeout(timer);
        timer = setTimeout(flush, TITLE_DEBOUNCE_MS);
      });
      titleSubscriptions.set(threadId, {
        unsubscribe: () => {
          if (timer !== null) clearTimeout(timer);
          subscription.unsubscribe?.();
        },
        flush,
      });
    } catch (_) {}
  }

  function normalizedThreadState(value: unknown): string | null {
    const raw = typeof value === "string"
      ? value
      : firstString(
          (value as { state?: unknown } | null)?.state,
          (value as { value?: unknown } | null)?.value,
        );
    if (!raw) return null;
    switch (raw.toLowerCase().replaceAll("_", "-")) {
      case "running":
      case "thinking":
      case "working":
        return "running";
      case "awaiting-approval":
      case "awaiting-input":
      case "needs-input":
      case "blocked":
        return "awaiting-approval";
      case "idle":
      case "done":
      case "complete":
      case "completed":
        return "idle";
      case "error":
      case "failed":
        return "error";
      default:
        return null;
    }
  }

  function normalizedTurnOutcome(value: unknown): string {
    switch (String(value || "done").toLowerCase()) {
      case "error":
      case "failed": return "error";
      case "cancelled":
      case "canceled":
      case "interrupted": return "cancelled";
      default: return "done";
    }
  }

  function reconcileThreadState(threadId: string, value: unknown): void {
    const state = normalizedThreadState(value);
    if (!state) return;
    const lifecycle = lifecycleFor(threadId);
    lifecycle.authoritativeState = state;
    const cwd = cwdFromEnv();
    switch (state) {
      case "running":
        if (lifecycle.inFlightTools === 0) {
          updateThreadPresentation(threadId, PRESENTATION.thinking);
        } else {
          projectThreadPresentation(threadId);
        }
        sendHook("lifecycle", threadId, cwd, {
          agent_state: state,
          ...turnPayload(lifecycle),
        });
        break;
      case "awaiting-approval":
        lifecycle.inFlightTools = 0;
        updateThreadPresentation(threadId, PRESENTATION.needsInput);
        sendHook("lifecycle", threadId, cwd, {
          agent_state: state,
          notification_type: "permission_prompt",
          ...turnPayload(lifecycle),
        });
        break;
      case "idle": {
        const pending = lifecycle.pendingTurn;
        if (!pending) {
          lifecycle.inFlightTools = 0;
          if (!lifecycle.terminalEventEmitted) {
            updateThreadPresentation(threadId, PRESENTATION.idle);
          }
          break;
        }
        lifecycle.inFlightTools = 0;
        lifecycle.pendingTurn = null;
        if (lifecycle.terminalEventEmitted) break;
        lifecycle.terminalEventEmitted = true;
        const outcome = pending.outcome;
        if (outcome === "done") {
          updateThreadPresentation(threadId, PRESENTATION.done);
          wsLog("turn complete", "success");
        } else if (outcome === "cancelled") {
          updateThreadPresentation(threadId, PRESENTATION.interrupted);
          wsLog("turn interrupted", "warning");
        } else {
          updateThreadPresentation(threadId, PRESENTATION.error);
          wsLog("turn errored", "error");
        }
        sendHook("lifecycle", threadId, cwd, {
          agent_state: state,
          turn_outcome: outcome,
          ...turnPayload(lifecycle, pending),
          ...(outcome === "error" ? {
            notification_type: "error",
          } : {}),
        });
        lifecycle.activeTurnId = null;
        break;
      }
      case "error": {
        const pending = lifecycle.pendingTurn;
        const outcome = pending?.outcome === "cancelled" ? "cancelled" : "error";
        lifecycle.inFlightTools = 0;
        lifecycle.pendingTurn = null;
        if (lifecycle.terminalEventEmitted) break;
        lifecycle.terminalEventEmitted = true;
        updateThreadPresentation(threadId, PRESENTATION.error);
        wsLog("turn errored", "error");
        sendHook("lifecycle", threadId, cwd, {
          agent_state: state,
          turn_outcome: outcome,
          notification_type: "error",
          ...turnPayload(lifecycle, pending),
        });
        lifecycle.activeTurnId = null;
        break;
      }
    }
  }

  function refreshThreadState(threadId: string, thread?: AmpThread): void {
    const observable = thread?.state;
    if (!observable?.get) return;
    const lifecycle = lifecycleFor(threadId);
    const version = lifecycle.observationVersion;
    let lookup: Promise<unknown> | unknown;
    try {
      lookup = observable.get();
    } catch (_) {
      return;
    }
    void withLookupTimeout(lookup)
      .then((value) => {
        if (version === lifecycleFor(threadId).observationVersion) {
          reconcileThreadState(threadId, value);
        }
      })
      .catch(() => {});
  }

  function watchThreadState(threadId: string, thread?: AmpThread): void {
    const observable = thread?.state;
    if (!observable) return;
    const alreadySubscribed = stateSubscriptions.has(threadId);
    if (observable.subscribe && !alreadySubscribed) {
      try {
        const subscription = observable.subscribe((value) => {
          lifecycleFor(threadId).observationVersion += 1;
          reconcileThreadState(threadId, value);
        });
        stateSubscriptions.set(threadId, { unsubscribe: () => subscription.unsubscribe?.() });
      } catch (_) {}
    }
    if (!alreadySubscribed || !stateSubscriptions.has(threadId)) {
      refreshThreadState(threadId, thread);
    }
  }

  function hasThreadStateCapability(thread?: AmpThread): boolean {
    return typeof thread?.state?.get === "function"
      || typeof thread?.state?.subscribe === "function";
  }

  function threadFromActiveValue(value: unknown): AmpThread | undefined {
    const wrapped = value as {
      current?: AmpThread | null;
      value?: AmpThread | null;
      thread?: AmpThread | null;
    } | null;
    const candidate = value && typeof value === "object" && firstString((value as AmpThread).id)
      ? value as AmpThread
      : wrapped?.current || wrapped?.value || wrapped?.thread || activeThread?.current || undefined;
    const threadId = firstString(value, candidate?.id, activeThread?.current?.id);
    if (!threadId) return undefined;
    const remembered = threadById.get(threadId);
    if (remembered) return remembered;
    try {
      const resolved = threads?.get?.(threadId);
      if (resolved) {
        threadById.set(threadId, resolved);
        return resolved;
      }
    } catch (_) {}
    if (candidate) threadById.set(threadId, candidate);
    return candidate;
  }

  function reconcileActiveThread(value: unknown): void {
    const thread = threadFromActiveValue(value);
    const threadId = firstString(value, thread?.id, activeThread?.current?.id);
    if (!threadId) {
      presentedThreadId = null;
      clearStatus();
      return;
    }
    presentedThreadId = threadId;
    watchThreadTitle(threadId, thread);
    watchThreadState(threadId, thread);
    projectThreadPresentation(threadId);
  }

  const activeThreadSubscription = (() => {
    if (!activeThread?.subscribe) return null;
    try {
      return activeThread.subscribe(reconcileActiveThread);
    } catch (_) {
      return null;
    }
  })();

"""#
}
