import { preferenceStorage } from "../browser-storage";
import { useEffect, useRef } from "react";
import type { CommandGroup, CwdCheck, CwdHarnessRequest, Provider, SessionOption, SessionState } from "../session";

/** Check restored sessions once per cwd on each connection, independently of composer edits. */
export function useSessionCwdCheck({ ready, connectionEpoch, phase, session, checkCwd }: Pick<SessionState,
  "ready" | "connectionEpoch" | "phase" | "session" | "checkCwd"
>) {
  const requested = useRef({ epoch: connectionEpoch, cwds: new Set<string>() });
  // Keep the lifecycle check independent from the callback identity. A session
  // render may replace the action object while a stream event is folded; that
  // must not turn a once-per-connection check into one request per event.
  const checkCwdRef = useRef(checkCwd);
  checkCwdRef.current = checkCwd;
  const cwd = session?.cwd;
  useEffect(() => {
    if (requested.current.epoch !== connectionEpoch) {
      requested.current = { epoch: connectionEpoch, cwds: new Set() };
    }
    if (!ready || phase !== "chat" || !cwd || requested.current.cwds.has(cwd)) return;
    if (checkCwdRef.current(cwd)) requested.current.cwds.add(cwd);
  }, [connectionEpoch, cwd, phase, ready]);
}

export function useDefaultCwd(
  defaultCwd: string,
  cwd: string,
  setCwd: (v: string) => void,
  committedCwd: string,
  setCommittedCwd: (v: string) => void,
) {
  useEffect(() => {
    if (!defaultCwd) return;
    if (!cwd) setCwd(defaultCwd);
    if (!committedCwd) setCommittedCwd(defaultCwd);
  }, [committedCwd, cwd, defaultCwd, setCommittedCwd, setCwd]);
}

export function useProviderFallback(providers: Provider[], provider: string, setProvider: (v: string) => void) {
  useEffect(() => {
    const installed = providers.filter((p) => p.installed !== false);
    if (installed.length && !installed.some((p) => p.id === provider)) setProvider(installed[0].id);
  }, [providers, provider, setProvider]);
}

export function useProviderCatalogs(
  ready: boolean,
  connectionEpoch: number,
  providers: Provider[],
  activeProvider: string,
  cwd: string,
  requestProviderOptions: (provider: string, cwd: string) => void,
  // Chat receives command groups from the stream and has no use for the
  // provider catalog. The composer passes this callback to opt into discovery.
  requestProviderCommands?: (provider: string, cwd: string) => void,
) {
  useEffect(() => {
    if (!ready || !cwd) return;
    for (const provider of providers) {
      if (provider.installed === false) continue;
      requestProviderOptions(provider.id, cwd);
    }
    if (requestProviderCommands && activeProvider && providers.some((p) => p.id === activeProvider && p.installed !== false)) {
      requestProviderCommands(activeProvider, cwd);
    }
  }, [activeProvider, connectionEpoch, cwd, providers, ready, requestProviderCommands, requestProviderOptions]);
}

export function useFileCatalog(
  ready: boolean,
  connectionEpoch: number,
  cwd: string,
  requestFiles: (cwd: string, query?: string) => void,
) {
  useEffect(() => {
    if (!ready || !cwd) return;
    requestFiles(cwd);
  }, [connectionEpoch, cwd, ready, requestFiles]);
}

export function withFileTrigger(groups: CommandGroup[], files: string[]): CommandGroup[] {
  return [
    ...groups,
    { trigger: "@", commands: files.map((name) => ({ name, description: "file" })) },
  ];
}

export function providerOptionMap(providers: Provider[], providerOptions: Record<string, SessionOption[]>, capabilities: Record<string, { options: SessionOption[] }>): Record<string, SessionOption[]> {
  return Object.fromEntries(providers.map((p) => [
    p.id,
    providerOptions[p.id]?.length ? providerOptions[p.id] : capabilities[p.id]?.options ?? [],
  ]));
}

export function loadingProviderOptionIds(
  providers: Provider[],
  providerOptions: Record<string, SessionOption[]>,
): ReadonlySet<string> {
  return new Set(
    providers
      .filter((provider) => provider.installed !== false && !Object.hasOwn(providerOptions, provider.id))
      .map((provider) => provider.id),
  );
}

export function useCwdValidation(
  ready: boolean,
  connectionEpoch: number,
  committedCwd: string,
  draftCwd: string,
  defaultCwd: string,
  cwdChecks: Record<string, CwdCheck>,
  checkCwd: (cwd: string) => CwdHarnessRequest | null,
  setCwd: (cwd: string) => void,
  setCommittedCwd: (cwd: string) => void,
) {
  const pendingRequest = useRef<CwdHarnessRequest | null>(null);
  useEffect(() => {
    pendingRequest.current = ready && committedCwd ? checkCwd(committedCwd) : null;
  }, [checkCwd, committedCwd, connectionEpoch, ready]);
  useEffect(() => {
    const checked = cwdChecks[committedCwd];
    const request = pendingRequest.current;
    if (
      !checked
      || !request
      || checked.requestId !== request.requestId
      || checked.connectionEpoch !== request.connectionEpoch
    ) return;
    pendingRequest.current = null;
    if (checked.ok || !defaultCwd || draftCwd !== committedCwd) return;
    setCwd(defaultCwd);
    setCommittedCwd(defaultCwd);
    preferenceStorage.setItem("agentui.cwd", defaultCwd);
  }, [committedCwd, cwdChecks, defaultCwd, draftCwd, setCommittedCwd, setCwd]);
}

export function useCwdErrorFallback(
  message: string,
  defaultCwd: string,
  setCwd: (cwd: string) => void,
  setCommittedCwd: (cwd: string) => void,
) {
  useEffect(() => {
    if (!message.includes("working directory does not exist") || !defaultCwd) return;
    setCwd(defaultCwd);
    setCommittedCwd(defaultCwd);
    preferenceStorage.setItem("agentui.cwd", defaultCwd);
  }, [defaultCwd, message, setCommittedCwd, setCwd]);
}
