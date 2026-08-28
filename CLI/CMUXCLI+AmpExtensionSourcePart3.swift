extension CMUXCLI {
    static let ampExtensionHandlers = #"""
  process.on("exit", () => {
    try { clearStatus(); } catch (_) {}
    try { activeThreadSubscription?.unsubscribe?.(); } catch (_) {}
    for (const subscription of titleSubscriptions.values()) {
      try { subscription.unsubscribe?.(); } catch (_) {}
    }
    for (const subscription of stateSubscriptions.values()) {
      try { subscription.unsubscribe?.(); } catch (_) {}
    }
    for (const subscription of resumableStateSubscriptions.values()) {
      try { subscription.unsubscribe?.(); } catch (_) {}
    }
  });

  amp.on("session.start", async (event: SessionStartEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    if (!sessionId) return;
    const lifecycle = lifecycleFor(sessionId);
    if (!lifecycle) return;
    lifecycle.presentation = PRESENTATION.idle;
    const thread = threadFrom(event, ctx);
    watchThreadTitle(sessionId, thread);
    watchThreadState(sessionId, thread);
    projectThreadPresentation(sessionId);
    sendHook("session-start", sessionId, cwdFromEnv(), titleExtra(sessionId));
    resolveThreadTitle(sessionId, thread);
  });

  amp.on("agent.start", async (event: AgentStartEvent, ctx) => {
    wsLog("prompt received");
    const sessionId = threadIdFrom(event, ctx);
    if (!sessionId) return;
    const lifecycle = lifecycleFor(sessionId);
    if (!lifecycle) return;
    lifecycle.observationVersion += 1;
    lifecycle.turnStateStartVersion = lifecycle.observationVersion;
    lifecycle.authoritativeState = "running";
    lifecycle.inFlightTools = 0;
    lifecycle.pendingTurn = null;
    lifecycle.terminalEventEmitted = false;
    lifecycle.activeTurnId = normalizedTurnId(event.id);
    updateThreadPresentation(sessionId, PRESENTATION.thinking);
    const thread = threadFrom(event, ctx);
    watchThreadTitle(sessionId, thread);
    watchThreadState(sessionId, thread);
    if (!titleByThread.has(sessionId)) {
      rememberTitle(sessionId, fallbackTitleFromAgentStart(event));
    }
    sendHook("prompt-submit", sessionId, cwdFromEnv(), {
      ...titleExtra(sessionId),
      ...turnPayload(lifecycle),
      prompt: event.message,
    });
    resolveThreadTitle(sessionId, thread);
  });

  amp.on("tool.call", async (event: ToolCallEvent) => {
    const sessionId = firstString(event.thread?.id);
    if (sessionId) {
      const lifecycle = lifecycleFor(sessionId);
      if (lifecycle?.authoritativeState === "running") {
        lifecycle.inFlightTools += 1;
        const { label, icon } = detailedToolStatus(event, helpers);
        updateThreadPresentation(sessionId, { label, icon, color: COLOR.active });
      }
    }
    // Request handlers must return a result. Amp gathers every plugin result and
    // gives error/reject/synthesize/modify outcomes precedence over `allow`.
    return { action: "allow" as const };
  });

  amp.on("tool.result", async (event: ToolResultEvent) => {
    if (event.status === "error") wsLog(`${event.tool} failed`, "error");
    const sessionId = firstString(event.thread?.id);
    if (!sessionId) return;
    const lifecycle = lifecycleFor(sessionId);
    if (!lifecycle) return;
    if (lifecycle.authoritativeState !== "running") return;
    lifecycle.inFlightTools = Math.max(0, lifecycle.inFlightTools - 1);
    if (lifecycle.inFlightTools === 0) {
      updateThreadPresentation(sessionId, PRESENTATION.thinking);
    }
  });

  amp.on("agent.end", async (event: AgentEndEvent, ctx) => {
    const sessionId = threadIdFrom(event, ctx);
    if (!sessionId) return;
    const lifecycle = lifecycleFor(sessionId);
    if (!lifecycle) return;
    lifecycle.inFlightTools = 0;
    lifecycle.pendingTurn = {
      outcome: normalizedTurnOutcome(event.status),
      turnId: normalizedTurnId(event.id) || lifecycle.activeTurnId,
      assistantMessage: lastAssistantMessage(event),
    };
    if (lifecycle.authoritativeState === "running") {
      updateThreadPresentation(sessionId, PRESENTATION.thinking);
    }
    const thread = threadFrom(event, ctx);
    resolveThreadTitle(sessionId, thread);
    // When available, authoritative thread.state owns completion so a lagging
    // agent.end/tool.result cannot race needs-input or a still-running process.
    // Older Amp releases expose no state observable, so agent.end is their
    // canonical terminal signal and reconciles through the same lifecycle hook.
    if (!hasThreadStateCapability(thread)) {
      reconcileThreadState(
        sessionId,
        lifecycle.pendingTurn?.outcome === "error" ? "error" : "idle",
      );
    } else if (lifecycle.terminalEventEmitted) {
      lifecycle.pendingTurn = null;
    } else if (
      lifecycle.observationVersion > lifecycle.turnStateStartVersion
      && (lifecycle.authoritativeState === "idle" || lifecycle.authoritativeState === "error")
    ) {
      reconcileThreadState(sessionId, lifecycle.authoritativeState);
    } else {
      refreshThreadState(sessionId, thread);
    }
  });
}
"""#
}
