import { useMemo, useState, type ReactNode } from "react";
import { Tooltip } from "@base-ui-components/react/tooltip";
import { CmdkMenu, type CmdkGroup } from "./components/CmdkMenu";
import { StatusRow } from "./components/StatusRow";
import { ActivityIndicatorBlock, Blocks, ToolBlock, TurnActions, type ToolBlockVariant } from "./components/Transcript";
import { BarsIcon, PinwheelSpinner, ProviderIcon } from "./components/icons";
import { HintTooltip } from "./components/Tooltips";
import { useOverlayScrollbars } from "./hooks/useOverlayScrollbars";
import type { OptionValue, SessionOption } from "./session";
import {
  activityScenarios,
  galleryActions,
  galleryCommands,
  galleryOptions,
  galleryProviders,
  longConversationBlocks,
  stressConversationBlocks,
  turnSummaryBlocks,
} from "./gallery-fixtures";
import { groupTurns } from "./turns";

const cwd = "/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-agent-chat-ui/agent-chat";

function setOption(options: SessionOption[], id: string, value: OptionValue): SessionOption[] {
  return options.map((o) => o.id === id ? { ...o, value } : o);
}

function Section({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section className="gallery-section" id={id}>
      <h2>{title}</h2>
      <div className="gallery-section-body">{children}</div>
    </section>
  );
}

function DemoStatusRow({
  provider,
  running = false,
}: {
  provider: string;
  running?: boolean;
}) {
  const [options, setOptions] = useState(() => galleryOptions[provider] ?? []);
  const [openOptionId, setOpenOptionId] = useState<string | null>(null);
  return (
    <div className="gallery-card compact">
      <StatusRow
        provider={provider}
        providers={galleryProviders}
        allProviderOptions={galleryOptions}
        onProviderModelChange={(nextProvider, model) => console.log("gallery model", nextProvider, model)}
        cwd={cwd}
        options={options}
        onChange={(id, value) => setOptions((current) => setOption(current, id, value))}
        openOptionId={openOptionId}
        setOpenOptionId={setOpenOptionId}
        running={running}
      />
    </div>
  );
}

function ComposerMock({ state }: { state: "idle" | "starting" | "draft" | "error" }) {
  const provider = state === "error" ? "claude" : "codex";
  return (
    <div className="gallery-composer-wrap">
      <div id="composer-card">
        <div className="input-wrap">
          <textarea
            id="prompt-input"
            readOnly
            disabled={state === "starting"}
            value={state === "draft" ? "Draft prompt with @src/App.tsx and /review" : ""}
            placeholder="Describe a task or ask a question..."
          />
        </div>
        <StatusRow
          provider={provider}
          providers={galleryProviders}
          allProviderOptions={galleryOptions}
          onProviderModelChange={(p, model) => console.log("gallery composer pick", p, model)}
          cwd={cwd}
          options={galleryOptions[provider]}
          onChange={(id, value) => console.log("gallery composer option", id, value)}
          openOptionId={null}
          setOpenOptionId={() => {}}
          trailing={(
            <button className="send" type="button" aria-label="Start" disabled={state === "starting"}>
              {state === "starting" ? <PinwheelSpinner size={14} /> : <span aria-hidden>↑</span>}
            </button>
          )}
        />
      </div>
      {state === "error" ? <div className="composer-error">working directory does not exist: /missing/gallery/path</div> : null}
    </div>
  );
}

function pickerGroups(trigger: "/" | "$" | "@"): CmdkGroup[] {
  const group = galleryCommands.find((g) => g.trigger === trigger);
  return [{
    id: trigger,
    label: trigger === "@" ? "Files" : trigger === "$" ? "Skills" : "Commands",
    items: (group?.commands ?? []).map((cmd, i) => ({
      id: `${trigger}${cmd.name}`,
      label: `${trigger}${cmd.name}`,
      description: cmd.description,
      selected: i === 1,
      onSelect: () => console.log("gallery command", trigger, cmd.name),
    })),
  }];
}

function overflowGroups(): CmdkGroup[] {
  return galleryOptions.codex
    .filter((o) => ["approvals", "sandbox"].includes(o.id))
    .map((option) => ({
      id: option.id,
      label: option.label,
      items: (option.choices ?? []).map((choice) => ({
        id: `${option.id}:${choice.value}`,
        label: choice.label,
        description: choice.description,
        selected: choice.value === option.value,
        onSelect: () => console.log("gallery overflow", option.id, choice.value),
      })),
    }));
}

function optionGroups(option: SessionOption): CmdkGroup[] {
  return [{
    id: option.id,
    label: option.label,
    items: (option.choices ?? []).map((choice) => ({
      id: `${option.id}:${choice.value}`,
      label: choice.label,
      description: choice.description ?? choice.disabledReason,
      disabled: choice.disabled,
      selected: choice.value === option.value,
      icon: option.role === "effort" ? <BarsIcon filled={Math.max(1, Math.round((((option.choices ?? []).findIndex((c) => c.value === choice.value) + 1) / Math.max(1, option.choices?.length ?? 1)) * 4))} /> : undefined,
      onSelect: () => console.log("gallery option", option.id, choice.value),
    })),
  }];
}

const toolVariants: ToolBlockVariant[] = ["card", "inline", "rail", "oneliner", "terminal"];
const toolFixtures = [
  { kind: "tool" as const, toolId: "running", name: "bash", detail: "bun test", status: "running" as const },
  { kind: "tool" as const, toolId: "ok", name: "rg", detail: "SessionOption", status: "ok" as const, out: "src/App.tsx:850: SessionOption\nsrc/session.ts:24: SessionOption\n".repeat(8) },
  { kind: "tool" as const, toolId: "fail", name: "bash", detail: "bun run check", status: "fail" as const, out: "error TS2322: Type mismatch in a deliberately long line that should wrap or scroll without breaking the transcript column.\n" },
];

function GalleryPicker({ query = "" }: { query?: string }) {
  const installed = galleryProviders.filter((p) => p.installed !== false);
  const missing = galleryProviders.filter((p) => p.installed === false);
  const items = installed.flatMap((provider) => (galleryOptions[provider.id]?.find((o) => o.id === "model")?.choices ?? []).map((choice) => ({ provider, choice })))
    .filter(({ provider, choice }) => !query || `${provider.label} ${choice.label} ${choice.description ?? ""}`.toLowerCase().includes(query.toLowerCase()));
  return (
    <div className="model-picker-menu gallery-picker-static">
      <div className="model-picker-shell">
        {!query ? (
          <div className="model-picker-rail" role="tablist" aria-label="Harnesses">
            <div className="model-picker-rail-top">
              {installed.map((provider, i) => <button key={provider.id} className={"rail-btn" + (i === 0 ? " active" : "")}><ProviderIcon provider={provider} /></button>)}
            </div>
            <div className="model-picker-rail-bottom">
              {missing.map((provider) => <button key={provider.id} className="rail-btn missing"><ProviderIcon provider={provider} /></button>)}
            </div>
          </div>
        ) : null}
        <div className="model-picker-main">
          <div className="model-picker-search"><span>⌕</span><input readOnly value={query} placeholder="Search models..." /></div>
          <div className="model-picker-list">
            {items.length ? items.map(({ provider, choice }, i) => (
              <button key={`${provider.id}:${choice.value}`} className={"model-row" + (i === 1 ? " active" : "") + (choice.disabled ? " disabled" : "")}>
                <ProviderIcon provider={provider} />
                <span className="model-row-main">
                  <span className="model-row-name">{choice.label}</span>
                  <span className="model-row-subtitle">{choice.disabled ? choice.disabledReason : choice.description ?? provider.label}</span>
                </span>
              </button>
            )) : <div className="model-picker-empty">No models found</div>}
          </div>
        </div>
      </div>
    </div>
  );
}

export function GalleryApp() {
  useOverlayScrollbars();
  const [viewport, setViewport] = useState("1120px");
  const toc = useMemo(() => [
    ["status-row", "Status row"],
    ["composer", "Composer"],
    ["picker", "Unified picker"],
    ["menus", "Menus"],
    ["commands", "Command menus"],
    ["tooltips", "Tooltips"],
    ["turn-summary", "Turn summary"],
    ["transcript", "Transcript"],
    ["stress-transcript", "Stress transcript"],
    ["activity", "Activity states"],
    ["turn-actions", "Turn actions"],
    ["tool-variants", "Tool call variants"],
    ["scrollbars", "Scrollbar behavior"],
  ], []);
  const effort = galleryOptions.claude.find((o) => o.id === "effort")!;
  const context = galleryOptions.claude.find((o) => o.id === "context")!;
  const mode = galleryOptions.claude.find((o) => o.id === "permissionMode")!;
  return (
    <Tooltip.Provider delay={500} closeDelay={80} timeout={800}>
      <main id="gallery-main">
        <header className="gallery-header">
          <h1>Agent Chat Gallery</h1>
          <p>Mock-driven visual QA surface. No WebSocket, no provider process, no live sessions.</p>
          <div className="gallery-viewports">
            {["320px", "480px", "660px", "900px", "1120px", "1400px"].map((w) => (
              <button key={w} className={viewport === w ? "active" : ""} onClick={() => setViewport(w)}>{w}</button>
            ))}
          </div>
          <nav className="gallery-toc" aria-label="Gallery sections">
            {toc.map(([id, label]) => <a key={id} href={`#${id}`}>{label}</a>)}
          </nav>
        </header>

        <div className="gallery-viewport-frame" style={{ maxWidth: viewport }}>
        <Section id="status-row" title="Status row">
          <div className="gallery-stack">
            {galleryProviders.map((provider) => (
              <div key={provider.id}>
                <div className="gallery-label">{provider.label} idle</div>
                <DemoStatusRow provider={provider.id} />
              </div>
            ))}
            {galleryProviders.filter((p) => p.installed !== false).map((provider) => (
              <div key={`${provider.id}:running`}>
                <div className="gallery-label">{provider.label} running</div>
                <DemoStatusRow provider={provider.id} running />
              </div>
            ))}
          </div>
        </Section>

        <Section id="composer" title="Composer">
          <div className="gallery-stack">
            <div><div className="gallery-label">Idle</div><ComposerMock state="idle" /></div>
            <div><div className="gallery-label">Draft</div><ComposerMock state="draft" /></div>
            <div><div className="gallery-label">Invalid cwd error</div><ComposerMock state="error" /></div>
          </div>
        </Section>

        <Section id="picker" title="Unified picker">
          <div className="gallery-grid two">
            <div><div className="gallery-label">Rail view, disabled row, not-installed rail item</div><GalleryPicker /></div>
            <div><div className="gallery-label">Searching view across harnesses</div><GalleryPicker query="gpt" /></div>
          </div>
        </Section>

        <Section id="menus" title="Effort, context, mode, overflow menus">
          <div className="gallery-grid">
            <div><div className="gallery-label">Effort menu</div><CmdkMenu groups={optionGroups(effort)} inline className="option-menu gallery-inline-menu" /></div>
            <div><div className="gallery-label">Context menu</div><CmdkMenu groups={optionGroups(context)} inline className="option-menu gallery-inline-menu" /></div>
            <div><div className="gallery-label">Mode menu</div><CmdkMenu groups={optionGroups(mode)} inline className="option-menu gallery-inline-menu" /></div>
            <div><div className="gallery-label">Codex overflow</div><div className="overflow-menu menu gallery-inline-overflow"><CmdkMenu groups={overflowGroups()} inline /></div></div>
          </div>
        </Section>

        <Section id="commands" title="Command menus">
          <div className="gallery-grid">
            <div><div className="gallery-label">Slash commands</div><CmdkMenu groups={pickerGroups("/")} inline className="mention-menu gallery-inline-menu" /></div>
            <div><div className="gallery-label">Codex skills</div><CmdkMenu groups={pickerGroups("$")} inline className="mention-menu gallery-inline-menu" /></div>
            <div><div className="gallery-label">File references</div><CmdkMenu groups={pickerGroups("@")} inline className="mention-menu gallery-inline-menu" /></div>
            <div><div className="gallery-label">Empty state</div><CmdkMenu groups={[{ id: "empty", label: "No commands", items: [] }]} inline className="mention-menu gallery-inline-menu" /></div>
          </div>
        </Section>

        <Section id="tooltips" title="Tooltips">
          <div className="gallery-tooltip-row">
            {galleryProviders.slice(0, 4).map((provider) => (
              <HintTooltip key={provider.id} label={`Tooltip for ${provider.label}`}>
                <button className="row-control" type="button"><ProviderIcon provider={provider} /><span>{provider.label}</span></button>
              </HintTooltip>
            ))}
            <Tooltip.Root open>
              <Tooltip.Trigger render={<button className="row-control" type="button">Forced open</button>} />
              <Tooltip.Portal>
                <Tooltip.Positioner sideOffset={7}>
                  <Tooltip.Popup className="tooltip"><span>Forced tooltip preview</span><kbd>⌃⇧T</kbd></Tooltip.Popup>
                </Tooltip.Positioner>
              </Tooltip.Portal>
            </Tooltip.Root>
          </div>
        </Section>

        <Section id="turn-summary" title="Turn summary">
          <div className="gallery-grid two">
            <div className="gallery-transcript small">
              <div className="gallery-label">Collapsed summary</div>
              <Blocks blocks={turnSummaryBlocks} status="idle" actions={galleryActions} onFork={() => {}} forkPending={false} />
            </div>
            <div className="gallery-transcript small">
              <div className="gallery-label">Expanded activity list</div>
              <Blocks
                blocks={turnSummaryBlocks}
                status="idle"
                actions={galleryActions}
                onFork={() => {}}
                forkPending={false}
                initialExpandedTurns={{ [groupTurns(turnSummaryBlocks, "idle")[0].id]: true }}
              />
            </div>
            <div className="gallery-transcript small">
              <div className="gallery-label">One item expanded to detail</div>
              <Blocks
                blocks={turnSummaryBlocks}
                status="idle"
                actions={galleryActions}
                onFork={() => {}}
                forkPending={false}
                initialExpandedTurns={{ [groupTurns(turnSummaryBlocks, "idle")[0].id]: true }}
                initialExpandedItems={{ [`${groupTurns(turnSummaryBlocks, "idle")[0].id}:1`]: true }}
              />
            </div>
          </div>
        </Section>

        <Section id="transcript" title={`Transcript (${longConversationBlocks.length} blocks)`}>
          <div className="gallery-transcript">
            <Blocks
              blocks={longConversationBlocks}
              status="idle"
              actions={galleryActions}
              onFork={() => console.log("gallery fork")}
              forkPending={false}
              thinkingDefaultOpen
              fileDiffs={{ "src/ChatMarkdown.tsx": "diff --git a/src/ChatMarkdown.tsx b/src/ChatMarkdown.tsx\nnew file mode 100644\n--- /dev/null\n+++ b/src/ChatMarkdown.tsx\n@@ -0,0 +1,3 @@\n+import ReactMarkdown from \"react-markdown\";\n+export function ChatMarkdown() {}\n+// highlighted diff preview" }}
            />
          </div>
        </Section>

        <Section id="stress-transcript" title={`Virtualization stress transcript (${stressConversationBlocks.length} blocks)`}>
          <div className="gallery-transcript">
            <Blocks blocks={stressConversationBlocks} status="idle" actions={galleryActions} onFork={() => {}} forkPending={false} />
          </div>
        </Section>

        <Section id="activity" title="Activity states">
          <div className="gallery-grid two">
            {activityScenarios.map((scenario) => (
              <div key={scenario.id} className="gallery-transcript small">
                <div className="gallery-label">{scenario.label}</div>
                <Blocks blocks={scenario.blocks} status={scenario.status} actions={galleryActions} onFork={() => {}} forkPending={false} thinkingDefaultOpen />
              </div>
            ))}
            <div className="gallery-transcript small">
              <div className="gallery-label">Elapsed indicator forced to 12s</div>
              <ActivityIndicatorBlock label="Thinking" startedAt={Date.now() - 12_000} />
            </div>
          </div>
        </Section>

        <Section id="turn-actions" title="Turn actions">
          <div className="gallery-card">
            <TurnActions stats="24289 in · 14 out · $0.18 · 5.9s" text="Markdown response body" actions={galleryActions} onFork={() => console.log("gallery fork")} forkPending={false} />
            <TurnActions stats="" text="No stats response" actions={galleryActions} onFork={() => console.log("gallery fork")} forkPending={false} copiedPreview />
            <TurnActions stats="100 in · 20 out · 2.1s" text="Pending fork response" actions={galleryActions} onFork={() => console.log("gallery fork")} forkPending />
          </div>
        </Section>

        <Section id="tool-variants" title="Tool call variants">
          <div className="gallery-tool-variants">
            {["480px", "100%"].map((width) => (
              <div className="gallery-tool-width" key={width} style={{ maxWidth: width }}>
                <div className="gallery-label">{width === "480px" ? "Narrow 480" : "Default width"}</div>
                {toolVariants.map((variant) => (
                  <div className="gallery-tool-variant" key={`${width}:${variant}`}>
                    <div className="gallery-label">{variant}</div>
                    {toolFixtures.map((tool) => (
                      <ToolBlock key={tool.toolId} b={tool} variant={variant} defaultOpen={tool.status !== "running"} />
                    ))}
                  </div>
                ))}
              </div>
            ))}
          </div>
        </Section>

        <Section id="scrollbars" title="Scrollbar behavior">
          <div className="gallery-scrollbox">
            {Array.from({ length: 60 }, (_, i) => <p key={i}>Scrollable gallery row {i}: overlay scrollbar thumb should appear only while scrolling.</p>)}
            <pre>{"wide ".repeat(80)}</pre>
          </div>
        </Section>
        </div>
      </main>
    </Tooltip.Provider>
  );
}
