import { useEffect } from "react";
import type { CommandGroup, Provider, SessionOption } from "../session";

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
  requestProviderCommands: (provider: string, cwd: string) => void,
) {
  useEffect(() => {
    if (!ready || !cwd) return;
    for (const provider of providers) {
      if (provider.installed === false) continue;
      requestProviderOptions(provider.id, cwd);
    }
    if (activeProvider && providers.some((p) => p.id === activeProvider && p.installed !== false)) {
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

export function useCwdValidation(
  ready: boolean,
  connectionEpoch: number,
  cwd: string,
  defaultCwd: string,
  cwdChecks: Record<string, { ok: boolean; message?: string }>,
  checkCwd: (cwd: string) => void,
  setCwd: (cwd: string) => void,
  setCommittedCwd: (cwd: string) => void,
) {
  useEffect(() => {
    if (ready && cwd) checkCwd(cwd);
  }, [checkCwd, connectionEpoch, cwd, ready]);
  useEffect(() => {
    const checked = cwdChecks[cwd];
    if (!checked || checked.ok || !defaultCwd) return;
    setCwd(defaultCwd);
    setCommittedCwd(defaultCwd);
    localStorage.setItem("agentui.cwd", defaultCwd);
  }, [cwd, cwdChecks, defaultCwd, setCommittedCwd, setCwd]);
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
    localStorage.setItem("agentui.cwd", defaultCwd);
  }, [defaultCwd, message, setCommittedCwd, setCwd]);
}
