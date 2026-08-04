import { useEffect, useLayoutEffect, useMemo, useRef, useState, type RefObject } from "react";
import { useCtx } from "../context";
import { readStoredProviderOptions, persistOptionsSnapshot, updateStoredProviderOption } from "../options-store";
import type { OptionValue, SessionOption } from "../session";
import { ArrowUp } from "./icons";
import { isCtrlJ, insertNewlineAtCaret, useCommandMenu } from "./CommandMenu";
import { optionAcceptsValue } from "./options";
import { StatusRow } from "./StatusRow";
import { Blocks } from "./Transcript";
import { ShortcutOverlay, useKeymap } from "../hooks/useKeymap";
import { useAutoGrow } from "../hooks/useAutoGrow";
import { providerOptionMap, useFileCatalog, useProviderCatalogs, withFileTrigger } from "../hooks/useCatalogs";

function usePersistSessionOptions(provider: string | undefined, options: SessionOption[], skip = false) {
  useEffect(() => {
    if (skip || !provider || !options.length) return;
    persistOptionsSnapshot(provider, options);
  }, [provider, options, skip]);
}

function useRestoreModelScopedOptions({
  provider,
  options,
  setOption,
  pendingModelRestoreRef,
}: {
  provider: string | undefined;
  options: SessionOption[];
  setOption: (id: string, value: OptionValue) => void;
  pendingModelRestoreRef: RefObject<string | null>;
}) {
  useEffect(() => {
    const pending = pendingModelRestoreRef.current;
    if (!provider || !pending || !options.length) return;
    const model = options.find((o) => o.id === "model");
    if (model?.value !== pending) return;
    const stored = readStoredProviderOptions(provider);
    for (const id of ["effort", "context", "fastMode"]) {
      const option = options.find((o) => o.id === id);
      const value = stored[id];
      if (option && value !== undefined && option.value !== value && optionAcceptsValue(option, value)) {
        setOption(id, value as OptionValue);
      }
    }
    pendingModelRestoreRef.current = null;
  }, [options, pendingModelRestoreRef, provider, setOption]);
}

function useStickToBottom(scrollRef: RefObject<HTMLDivElement | null>, stickRef: RefObject<boolean>, blocks: unknown[], running: boolean) {
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (el && stickRef.current) el.scrollTop = el.scrollHeight;
  }, [blocks, running, scrollRef, stickRef]);
}

export function Chat() {
  const { ready, connectionEpoch, providers, capabilities, providerOptions, session, blocks, options, actions, commands, filesByCwd, fileDiffs, ctrlJ, forkPending, reply, stop, setOption, fork, compose, requestProviderOptions, requestProviderCommands, requestFiles, requestFileDiff } = useCtx();
  const [text, setText] = useState("");
  const [openOptionId, setOpenOptionId] = useState<string | null>(null);
  const [helpOpen, setHelpOpen] = useState(false);
  const taRef = useAutoGrow(text, 200);
  const scrollRef = useRef<HTMLDivElement>(null);
  const stickRef = useRef(true);
  const pendingModelRestoreRef = useRef<string | null>(null);
  const cwd = session?.cwd ?? "";
  const commandGroups = useMemo(() => withFileTrigger(commands, filesByCwd[cwd] ?? []), [commands, cwd, filesByCwd]);
  const commandMenu = useCommandMenu(text, setText, commandGroups, taRef, ctrlJ);
  const allProviderOptions = providerOptionMap(providers, providerOptions, capabilities);
  const running = session?.status === "running";

  useRestoreModelScopedOptions({ provider: session?.provider, options, setOption, pendingModelRestoreRef });
  usePersistSessionOptions(session?.provider, options, pendingModelRestoreRef.current !== null);
  useProviderCatalogs(ready, connectionEpoch, providers, session?.provider ?? "", cwd, requestProviderOptions, requestProviderCommands);
  useFileCatalog(ready, connectionEpoch, cwd, requestFiles);
  useStickToBottom(scrollRef, stickRef, blocks, running);
  useKeymap({
    options,
    setOption,
    running,
    stop,
    helpOpen,
    setHelpOpen,
    popupOpen: commandMenu.open || Boolean(openOptionId),
    closePopup: () => {
      commandMenu.close();
      setOpenOptionId(null);
    },
    ctrlJ,
    inputRef: taRef,
    openModel: () => setOpenOptionId("modelPicker"),
  });

  const onScroll = () => {
    const el = scrollRef.current;
    if (el) stickRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
  };
  const submit = () => {
    const t = text.trim();
    if (!t) return;
    stickRef.current = true;
    reply(t);
    setText("");
  };
  const switchHarnessModel = (provider: string, model: string) => {
    if (!session) return;
    if (provider === session.provider) {
      if (model) {
        updateStoredProviderOption(provider, "model", model, options);
        pendingModelRestoreRef.current = model;
        setOption("model", model);
      }
      setOpenOptionId(null);
      return;
    }
    updateStoredProviderOption(provider, "model", model, allProviderOptions[provider] ?? []);
    localStorage.setItem("agentui.provider", provider);
    localStorage.setItem("agentui.cwd", session.cwd);
    sessionStorage.setItem("agentui.draft", text);
    compose();
  };

  return (
    <section id="chat-view">
      <div id="messages" ref={scrollRef} onScroll={onScroll}>
        <Blocks
          blocks={blocks}
          status={session?.status}
          actions={actions}
          onFork={fork}
          forkPending={forkPending}
          fileDiffs={fileDiffs}
          onFileDiff={(path) => { if (session) requestFileDiff(session.id, path); }}
        />
      </div>
      <div id="chat-input-row">
        <div id="chat-card">
          <div className="input-wrap chat-text-wrap">
            <textarea
              ref={taRef}
              id="chat-input"
              data-primary-textarea="true"
              placeholder="Reply…"
              value={text}
              onChange={(e) => setText(e.target.value)}
              onSelect={commandMenu.onSelect}
              onKeyUp={commandMenu.onSelect}
              onClick={commandMenu.onSelect}
              onKeyDown={(e) => {
                if (commandMenu.onKeyDown(e)) return;
                if (isCtrlJ(e)) { e.preventDefault(); insertNewlineAtCaret(text, setText, taRef); return; }
                if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); submit(); }
              }}
            />
            {commandMenu.menu}
          </div>
          <StatusRow
            provider={session?.provider ?? "agent"}
            providers={providers}
            allProviderOptions={allProviderOptions}
            onProviderModelChange={switchHarnessModel}
            cwd={session?.cwd ?? ""}
            options={options}
            onChange={setOption}
            openOptionId={openOptionId}
            setOpenOptionId={setOpenOptionId}
            running={running}
            trailing={(
              <div className="chat-actions">
                {running ? <button id="stop-btn" type="button" onClick={stop}>Stop</button> : null}
                <button className="send" type="button" aria-label="Send" disabled={!text.trim()} onClick={submit}>
                  <ArrowUp />
                </button>
              </div>
            )}
          />
        </div>
      </div>
      {helpOpen ? <ShortcutOverlay provider={session?.provider ?? "agent"} options={options} running={running} ctrlJ={ctrlJ} onClose={() => setHelpOpen(false)} /> : null}
    </section>
  );
}
