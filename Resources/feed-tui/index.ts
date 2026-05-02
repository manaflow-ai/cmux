import net from "node:net";
import { randomUUID } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import {
  Box,
  CliRenderEvents,
  ScrollBox,
  Text,
  createCliRenderer,
  type CliRenderer,
  type KeyEvent,
} from "@opentui/core";

type FeedStatus = "pending" | "resolved" | "expired" | string;

interface FeedOption {
  id: string;
  label: string;
}

interface FeedQuestion {
  id: string;
  prompt: string;
  multiSelect: boolean;
  options: FeedOption[];
}

interface FeedItem {
  id: string;
  requestId?: string;
  workstreamId: string;
  source: string;
  kind: string;
  status: FeedStatus;
  createdAt?: Date;
  title: string;
  detail: string;
  defaultMode?: string;
  questionMultiSelect: boolean;
  questionOptions: FeedOption[];
  questions: FeedQuestion[];
  canResolve: boolean;
}

interface FeedListResult {
  items?: Record<string, unknown>[];
}

const theme = {
  background: "#000000",
  backgroundMuted: "#070707",
  surface: "#101010",
  surfaceSelected: "#0F1825",
  border: "#2F2F2F",
  borderSelected: "#1D9BF0",
  textPrimary: "#F5F5F5",
  textMuted: "#9CA3AF",
  accent: "#1D9BF0",
  accentStrong: "#5CB9FF",
  pending: "#E5B567",
  success: "#8DDDB6",
  danger: "#E690A0",
} as const;

const layout = {
  columnMaxWidth: 64,
} as const;

class FeedSocketClient {
  constructor(private readonly socketPath: string, private readonly socketPassword?: string) {}

  public request<T>(method: string, params: Record<string, unknown> = {}, timeoutMs = 10_000): Promise<T> {
    return new Promise((resolve, reject) => {
      const socket = new net.Socket();
      const id = randomUUID();
      const payload = `${JSON.stringify({ id, method, params })}\n`;
      let buffer = "";
      let settled = false;
      let requestSent = !this.socketPassword;
      const timer = setTimeout(() => {
        finish(new Error(`${method} timed out`));
      }, timeoutMs);

      const finish = (error?: Error, value?: T) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        socket.destroy();
        if (error) {
          reject(error);
        } else {
          resolve(value as T);
        }
      };

      const sendRequest = () => {
        requestSent = true;
        socket.write(payload);
      };

      socket.setEncoding("utf8");
      socket.on("connect", () => {
        if (this.socketPassword) {
          socket.write(`auth ${this.socketPassword}\n`);
        } else {
          sendRequest();
        }
      });
      socket.on("data", (chunk) => {
        buffer += chunk;
        while (true) {
          const newlineIndex = buffer.indexOf("\n");
          if (newlineIndex === -1) {
            return;
          }
          const line = buffer.slice(0, newlineIndex).trim();
          buffer = buffer.slice(newlineIndex + 1);
          if (!line) {
            continue;
          }
          if (!requestSent) {
            if (line.startsWith("ERROR:")) {
              if (line.includes("Unknown command 'auth'")) {
                sendRequest();
                continue;
              }
              finish(new Error(line));
              return;
            }
            sendRequest();
            continue;
          }
          try {
            const response = JSON.parse(line) as {
              ok?: boolean;
              result?: T;
              error?: { code?: string; message?: string };
            };
            if (response.ok) {
              finish(undefined, response.result as T);
              return;
            }
            const code = response.error?.code ?? "error";
            const message = response.error?.message ?? "Unknown Feed error";
            finish(new Error(`${code}: ${message}`));
            return;
          } catch (error) {
            finish(error as Error);
            return;
          }
        }
      });
      socket.on("error", (error) => finish(error));
      socket.on("end", () => {
        if (!settled && buffer.trim().length === 0) {
          finish(new Error(`${method} returned no response`));
        }
      });
      socket.connect({ path: this.socketPath });
    });
  }
}

class FeedApp {
  private readonly renderer: CliRenderer;
  private readonly client: FeedSocketClient;
  private items: FeedItem[] = [];
  private selectedIndex = 0;
  private selectedItemId: string | undefined;
  private statusMessage = "Ready";
  private loading = false;
  private renderCycle = 0;
  private handlingKey = false;
  private stopped = false;
  private refreshTimer: NodeJS.Timeout | undefined;
  private feedbackItem: FeedItem | undefined;
  private feedbackText = "";
  private readonly questionSelections = new Map<string, Set<string>>();
  private readonly keyHandler = (key: KeyEvent) => {
    void this.handleKeySafely(key);
  };
  private readonly rendererRefreshHandler = () => {
    this.render();
  };

  constructor(renderer: CliRenderer, client: FeedSocketClient) {
    this.renderer = renderer;
    this.client = client;
  }

  public async start(): Promise<void> {
    this.renderer.on(CliRenderEvents.RESIZE, this.rendererRefreshHandler);
    this.renderer.on(CliRenderEvents.CAPABILITIES, this.rendererRefreshHandler);
    this.renderer.keyInput.on("keypress", this.keyHandler);
    this.render();
    writeReadyMarker("opentui-ready", {
      cwd: process.cwd(),
      screen_mode: this.renderer.screenMode,
    });
    await this.refresh("Loaded Feed.");
    this.refreshTimer = setInterval(() => {
      void this.refresh(undefined, false);
    }, 1_000);
  }

  public stop(): void {
    if (this.stopped) {
      return;
    }
    this.stopped = true;
    if (this.refreshTimer) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = undefined;
    }
    this.renderer.keyInput.off("keypress", this.keyHandler);
    this.renderer.off(CliRenderEvents.RESIZE, this.rendererRefreshHandler);
    this.renderer.off(CliRenderEvents.CAPABILITIES, this.rendererRefreshHandler);
    this.clearRoot();
    this.renderer.destroy();
  }

  private async refresh(status?: string, showErrors = true): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    try {
      const result = await this.client.request<FeedListResult>("feed.list", { pending_only: true });
      const nextItems = (result.items ?? [])
        .map(parseFeedItem)
        .filter((item): item is FeedItem => Boolean(item))
        .filter((item) => item.canResolve)
        .sort(compareLatestFirst);
      this.items = nextItems;
      this.restoreSelection();
      if (status) {
        this.statusMessage = status;
      }
    } catch (error) {
      if (showErrors) {
        this.statusMessage = `Feed error: ${formatError(error)}`;
      }
    } finally {
      this.loading = false;
      this.render();
    }
  }

  private render(): void {
    this.renderCycle += 1;
    const cycle = this.renderCycle;
    const selectedItem = this.items[this.selectedIndex];
    const pendingCount = this.items.filter((item) => item.status === "pending").length;

    this.clearRoot();
    this.renderer.root.add(
      Box(
        {
          id: "feed-shell",
          width: "100%",
          height: "100%",
          flexDirection: "column",
          backgroundColor: theme.background,
        },
        this.renderHeader(pendingCount),
        this.renderTimeline(),
        this.renderFooter(selectedItem),
      ),
    );

    void this.renderer.idle().then(() => {
      if (cycle !== this.renderCycle) {
        return;
      }
      this.scrollSelectedIntoView();
    });
  }

  private renderHeader(pendingCount: number) {
    const total = this.items.length;
    const right = this.renderer.width < 42
      ? `${pendingCount}/${total} pending`
      : `${pendingCount} pending  ${total} total  latest first`;
    return Box(
      {
        id: "feed-header",
        width: "100%",
        height: 3,
        borderStyle: "single",
        borderColor: theme.border,
        backgroundColor: theme.backgroundMuted,
        paddingLeft: 1,
        paddingRight: 1,
        flexDirection: "row",
        justifyContent: "space-between",
        alignItems: "center",
      },
      Text({ content: "cmux feed", fg: theme.accentStrong }),
      Text({ content: right, fg: theme.textMuted }),
    );
  }

  private renderTimeline() {
    if (this.items.length === 0) {
      const message = this.loading ? "Loading Feed..." : "No Feed items yet.";
      return Box(
        {
          id: "feed-empty",
          width: "100%",
          flexGrow: 1,
          alignItems: "center",
          justifyContent: "center",
          backgroundColor: theme.background,
        },
        Text({ content: message, fg: theme.textMuted }),
      );
    }

    return Box(
      {
        id: "feed-body",
        width: "100%",
        flexGrow: 1,
        alignItems: "center",
        backgroundColor: theme.background,
        paddingLeft: 1,
        paddingRight: 1,
      },
      ScrollBox(
        {
          id: "feed-scroll",
          width: "100%",
          maxWidth: layout.columnMaxWidth,
          height: "100%",
          viewportCulling: true,
          rootOptions: {
            backgroundColor: theme.background,
          },
          contentOptions: {
            padding: 1,
          },
          verticalScrollbarOptions: {
            trackOptions: {
              backgroundColor: theme.backgroundMuted,
              foregroundColor: theme.accent,
            },
          },
        },
        ...this.items.map((item, index) => this.renderCard(item, index === this.selectedIndex)),
      ),
    );
  }

  private renderCard(item: FeedItem, selected: boolean) {
    const statusColor = statusColorFor(item.status);
    const source = item.source || "agent";
    const textWidth = this.cardTextWidth();
    const title = wrapText(cleanText(item.title), textWidth, 2).join("\n");
    const detail = wrapText(cleanText(item.detail), textWidth, selected ? 6 : 3).join("\n");
    const meta = clamp(
      `${kindLabel(item.kind)}  ${relativeTime(item.createdAt)}`.trim(),
      Math.max(8, textWidth),
    );
    const actions = wrapText(this.actionText(item), textWidth, selected ? 2 : 1).join("\n");

    return Box(
      {
        id: cardId(item),
        width: "100%",
        borderStyle: "rounded",
        borderColor: selected ? theme.borderSelected : theme.border,
        backgroundColor: selected ? theme.surfaceSelected : theme.surface,
        padding: 1,
        marginBottom: 1,
        flexDirection: "column",
        gap: 1,
        overflow: "hidden",
      },
      Box(
        {
          width: "100%",
          flexDirection: "row",
          alignItems: "flex-start",
          gap: 1,
        },
        Box(
          {
            width: 4,
            height: 2,
            alignItems: "center",
            justifyContent: "center",
            borderStyle: "single",
            borderColor: selected ? theme.borderSelected : theme.border,
          },
          Text({ content: sourceInitial(source), fg: theme.accentStrong }),
        ),
        Box(
          {
            flexDirection: "column",
            flexGrow: 1,
          },
          Text({ content: clamp(source, Math.max(6, textWidth)), fg: theme.textPrimary }),
          Text({ content: meta, fg: theme.textMuted }),
        ),
        Text({ content: item.status.toUpperCase(), fg: statusColor }),
      ),
      Text({ content: title, fg: theme.textPrimary }),
      detail ? Text({ content: detail, fg: theme.textMuted }) : null,
      Text({ content: actions, fg: item.canResolve ? theme.accentStrong : theme.textMuted }),
    );
  }

  private renderFooter(selectedItem: FeedItem | undefined) {
    const width = this.statusTextWidth();
    if (this.feedbackItem) {
      const prompt = wrapText("Replan feedback. Enter sends, Esc cancels.", width, 2);
      const input = wrapText(`> ${this.feedbackText}_`, width, 3);
      const status = wrapText(this.statusMessage, width, 2);
      return Box(
        {
          id: "feed-footer",
          width: "100%",
          height: prompt.length + input.length + status.length + 2,
          borderStyle: "single",
          borderColor: theme.borderSelected,
          backgroundColor: theme.backgroundMuted,
          paddingLeft: 1,
          paddingRight: 1,
          flexDirection: "column",
        },
        Text({ content: prompt.join("\n"), fg: theme.textPrimary }),
        Text({ content: input.join("\n"), fg: theme.accentStrong }),
        Text({ content: status.join("\n"), fg: theme.textMuted }),
      );
    }

    const help = selectedItem ? this.helpText(selectedItem) : "j/k or arrows move  r refresh  q quit";
    const statusLines = wrapText(this.statusMessage, width, 2);
    const helpLines = wrapText(help, width, 4);
    return Box(
      {
        id: "feed-footer",
        width: "100%",
        height: statusLines.length + helpLines.length + 2,
        borderStyle: "single",
        borderColor: theme.border,
        backgroundColor: theme.backgroundMuted,
        paddingLeft: 1,
        paddingRight: 1,
        flexDirection: "column",
      },
      Text({ content: statusLines.join("\n"), fg: theme.textMuted }),
      Text({ content: helpLines.join("\n"), fg: theme.textPrimary }),
    );
  }

  private async handleKey(key: KeyEvent): Promise<void> {
    if (isCtrlC(key)) {
      this.stop();
      process.exit(0);
    }

    if (this.feedbackItem) {
      await this.handleFeedbackKey(key);
      return;
    }

    if (isKey(key, "q")) {
      this.stop();
      process.exit(0);
    }

    if (isKey(key, "j", "down")) {
      this.moveSelection(1);
      return;
    }

    if (isKey(key, "k", "up")) {
      this.moveSelection(-1);
      return;
    }

    if (isKey(key, "r")) {
      await this.refresh("Refreshed.");
      return;
    }

    const item = this.items[this.selectedIndex];
    if (!item) {
      return;
    }

    if (isKey(key, "f")) {
      if (item.kind === "exitPlan" && item.canResolve) {
        this.feedbackItem = item;
        this.feedbackText = "";
        this.statusMessage = "Tell the agent what to change.";
        this.render();
      } else {
        this.statusMessage = "Feedback is only available for pending plans.";
        this.render();
      }
      return;
    }

    if (isKey(key, "return", "enter")) {
      await this.resolveItem(item, "default");
      return;
    }

    const action = actionForKey(key);
    if (action) {
      if (!this.canUseAction(item, action)) {
        this.statusMessage = "Key is not available for this card.";
        this.render();
        return;
      }
      if (item.kind === "question" && item.questionMultiSelect && action.startsWith("option:")) {
        this.toggleQuestionSelection(item, action);
        return;
      }
      await this.resolveItem(item, action);
    }
  }

  private async handleKeySafely(key: KeyEvent): Promise<void> {
    if (this.handlingKey) {
      return;
    }
    this.handlingKey = true;
    try {
      await this.handleKey(key);
    } catch (error) {
      this.statusMessage = `Error: ${formatError(error)}`;
      this.render();
    } finally {
      this.handlingKey = false;
    }
  }

  private async handleFeedbackKey(key: KeyEvent): Promise<void> {
    if (isKey(key, "escape")) {
      this.feedbackItem = undefined;
      this.feedbackText = "";
      this.statusMessage = "Replan cancelled.";
      this.render();
      return;
    }

    if (isKey(key, "return", "enter")) {
      const item = this.feedbackItem;
      const feedback = this.feedbackText.trim();
      this.feedbackItem = undefined;
      this.feedbackText = "";
      if (!item || !feedback) {
        this.statusMessage = "Replan cancelled.";
        this.render();
        return;
      }
      await this.resolveItem(item, "feedback", feedback);
      return;
    }

    if (isKey(key, "backspace", "delete")) {
      this.feedbackText = this.feedbackText.slice(0, -1);
      this.render();
      return;
    }

    if (!key.ctrl && !key.meta && key.sequence && key.sequence.length === 1 && key.sequence >= " ") {
      this.feedbackText = `${this.feedbackText}${key.sequence}`.slice(0, 500);
      this.render();
    }
  }

  private moveSelection(delta: number): void {
    this.selectedIndex = Math.max(0, Math.min(this.items.length - 1, this.selectedIndex + delta));
    this.selectedItemId = this.items[this.selectedIndex]?.id;
    this.render();
  }

  private restoreSelection(): void {
    if (this.selectedItemId) {
      const index = this.items.findIndex((item) => item.id === this.selectedItemId);
      if (index >= 0) {
        this.selectedIndex = index;
      }
    }
    this.selectedIndex = Math.max(0, Math.min(this.items.length - 1, this.selectedIndex));
    this.selectedItemId = this.items[this.selectedIndex]?.id;
  }

  private scrollSelectedIntoView(): void {
    const item = this.items[this.selectedIndex];
    if (!item) {
      return;
    }
    const scrollBox = this.renderer.root.findDescendantById("feed-scroll") as
      | { scrollChildIntoView?: (id: string) => void }
      | undefined;
    scrollBox?.scrollChildIntoView?.(cardId(item));
  }

  private async resolveItem(item: FeedItem, action: string, feedback?: string): Promise<void> {
    if (!item.canResolve || !item.requestId) {
      this.statusMessage = "Selected item is informational.";
      this.render();
      return;
    }

    try {
      switch (item.kind) {
        case "permissionRequest": {
          const mode = permissionMode(action);
          await this.client.request("feed.permission.reply", {
            request_id: item.requestId,
            mode,
          });
          this.statusMessage = `Permission ${mode} sent.`;
          break;
        }
        case "exitPlan": {
          if (action === "feedback") {
            await this.client.request("feed.exit_plan.reply", {
              request_id: item.requestId,
              mode: "deny",
              feedback: feedback ?? "",
            });
            this.statusMessage = "Replan feedback sent.";
            break;
          }
          const mode = planMode(action, item.defaultMode);
          await this.client.request("feed.exit_plan.reply", {
            request_id: item.requestId,
            mode,
          });
          this.statusMessage = `Plan ${mode} sent.`;
          break;
        }
        case "question": {
          const selections = this.questionSelectionsForReply(item, action);
          if (!selections) {
            this.statusMessage = "No option for selected question.";
            this.render();
            return;
          }
          await this.client.request("feed.question.reply", {
            request_id: item.requestId,
            selections,
          });
          this.questionSelections.delete(item.requestId);
          this.statusMessage = selections.length === 0 ? "Answered with no selections." : `Answered ${selections.length} option(s).`;
          break;
        }
      }
      await this.refresh(undefined, false);
    } catch (error) {
      this.statusMessage = `Reply failed: ${formatError(error)}`;
      this.render();
    }
  }

  private actionText(item: FeedItem): string {
    if (!item.canResolve) {
      return "Resolved or informational";
    }
    switch (item.kind) {
      case "permissionRequest":
        if (item.source === "codex") {
          return "Enter once | d deny";
        }
        return "Enter once | a always | l all | b bypass | d deny";
      case "exitPlan":
        return "Enter default | a auto | m manual | u ultra | b bypass | f replan | d deny";
      case "question":
        if (item.questionOptions.length === 0) {
          return "Enter sends empty answer";
        }
        return item.questionOptions
          .map((option, index) => {
            const prefix = this.questionOptionIsSelected(item, option.id) ? "[x]" : `${index + 1}`;
            return `${prefix} ${clamp(option.label, 18)}`;
          })
          .join(" | ") + (item.questionMultiSelect ? " | Enter sends selected" : "");
      default:
        return "";
    }
  }

  private helpText(item: FeedItem): string {
    return `${this.actionText(item)} | j/k move | r refresh | q quit`;
  }

  private cardTextWidth(): number {
    return Math.max(14, Math.min(layout.columnMaxWidth - 6, this.renderer.width - 10));
  }

  private statusTextWidth(): number {
    return Math.max(12, this.renderer.width - 4);
  }

  private clearRoot(): void {
    for (const child of this.renderer.root.getChildren()) {
      this.renderer.root.remove(child.id);
    }
  }

  private canUseAction(item: FeedItem, action: string): boolean {
    if (!item.canResolve) {
      return false;
    }
    switch (item.kind) {
      case "permissionRequest":
        if (item.source === "codex") {
          // Codex PermissionRequest hooks only accept allow/deny for this
          // invocation. Persistent allow/bypass modes are Claude/OpenCode-only.
          return ["deny"].includes(action);
        }
        return ["deny", "always", "all", "bypass"].includes(action);
      case "exitPlan":
        return ["deny", "always", "manual", "ultraplan", "bypass"].includes(action);
      case "question":
        return action === "default" || action.startsWith("option:");
      default:
        return false;
    }
  }

  private questionOptionIsSelected(item: FeedItem, optionId: string): boolean {
    if (!item.requestId) {
      return false;
    }
    return this.questionSelections.get(item.requestId)?.has(optionId) ?? false;
  }

  private toggleQuestionSelection(item: FeedItem, action: string): void {
    if (!item.requestId) {
      return;
    }
    const option = questionOption(item.questions[0]?.options ?? item.questionOptions, action);
    if (!option) {
      this.statusMessage = "No option for selected question.";
      this.render();
      return;
    }
    const selections = this.questionSelections.get(item.requestId) ?? new Set<string>();
    if (selections.has(option.id)) {
      selections.delete(option.id);
      this.statusMessage = `Unselected: ${option.label}`;
    } else {
      selections.add(option.id);
      this.statusMessage = `Selected: ${option.label}`;
    }
    this.questionSelections.set(item.requestId, selections);
    this.render();
  }

  private questionSelectionsForReply(item: FeedItem, action: string): string[] | undefined {
    const primaryQuestion = item.questions[0];
    const primaryOptions = primaryQuestion?.options ?? item.questionOptions;
    const primaryMultiSelect = primaryQuestion?.multiSelect ?? item.questionMultiSelect;
    if (primaryOptions.length === 0) {
      return action === "default" ? [] : undefined;
    }
    if (item.questions.length > 1 && action === "default") {
      return item.questions.map((question) => question.options[0]?.label ?? "");
    }
    if (primaryMultiSelect) {
      if (!item.requestId) {
        return undefined;
      }
      const selected = this.questionSelections.get(item.requestId) ?? new Set<string>();
      return primaryOptions
        .filter((option) => selected.has(option.id))
        .map((option) => option.label);
    }
    const option = action === "default" ? primaryOptions[0] : questionOption(primaryOptions, action);
    return option ? [option.label] : undefined;
  }
}

function parseFeedItem(raw: Record<string, unknown>): FeedItem | undefined {
  const id = stringValue(raw.id);
  const workstreamId = stringValue(raw.workstream_id);
  const source = stringValue(raw.source);
  const kind = stringValue(raw.kind);
  const status = stringValue(raw.status);
  if (!id || !workstreamId || !source || !kind || !status) {
    return undefined;
  }

  const questionOptions = Array.isArray(raw.question_options)
    ? parseFeedOptions(raw.question_options)
    : [];
  const questions = parseFeedQuestions(raw.questions, questionOptions, raw);

  const item: FeedItem = {
    id,
    requestId: stringValue(raw.request_id),
    workstreamId,
    source,
    kind,
    status,
    createdAt: dateValue(raw.created_at ?? raw.createdAt ?? raw.timestamp ?? raw.time),
    title: stringValue(raw.title) || defaultTitle(kind, raw),
    detail: detailText(kind, raw),
    defaultMode: stringValue(raw.default_mode),
    questionMultiSelect: raw.question_multi_select === true,
    questionOptions,
    questions,
    canResolve: status === "pending" &&
      Boolean(stringValue(raw.request_id)) &&
      ["permissionRequest", "exitPlan", "question"].includes(kind),
  };
  return item;
}

function parseFeedOptions(raw: unknown): FeedOption[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  return raw
    .map((option) => {
      if (!option || typeof option !== "object") {
        return undefined;
      }
      const optionRecord = option as Record<string, unknown>;
      const optionId = stringValue(optionRecord.id);
      const label = stringValue(optionRecord.label);
      return optionId && label ? { id: optionId, label } : undefined;
    })
    .filter((option): option is FeedOption => Boolean(option));
}

function parseFeedQuestions(raw: unknown, fallbackOptions: FeedOption[], item: Record<string, unknown>): FeedQuestion[] {
  if (Array.isArray(raw)) {
    const parsed = raw
      .map((question, index) => {
        if (!question || typeof question !== "object") {
          return undefined;
        }
        const record = question as Record<string, unknown>;
        const prompt = stringValue(record.prompt) || stringValue(record.question) || stringValue(record.header);
        const options = parseFeedOptions(record.options);
        if (!prompt && options.length === 0) {
          return undefined;
        }
        return {
          id: stringValue(record.id) || `question-${index + 1}`,
          prompt: prompt || "Answer the agent question.",
          multiSelect: record.multi_select === true || record.multiSelect === true,
          options,
        };
      })
      .filter((question): question is FeedQuestion => Boolean(question));
    if (parsed.length > 0) {
      return parsed;
    }
  }
  return [{
    id: "question-1",
    prompt: stringValue(item.question_prompt) || stringValue(item.title) || "Answer the agent question.",
    multiSelect: item.question_multi_select === true,
    options: fallbackOptions,
  }];
}

function defaultTitle(kind: string, raw: Record<string, unknown>): string {
  switch (kind) {
    case "permissionRequest":
      return `Permission: ${stringValue(raw.tool_name) || "tool"}`;
    case "exitPlan":
      return "Plan";
    case "question":
      return "Question";
    default:
      return kind;
  }
}

function detailText(kind: string, raw: Record<string, unknown>): string {
  switch (kind) {
    case "permissionRequest": {
      const tool = stringValue(raw.tool_name) || "tool";
      const input = raw.tool_input;
      const inputText = typeof input === "string" ? input : input ? JSON.stringify(input) : "";
      return inputText ? `${tool}: ${inputText}` : tool;
    }
    case "exitPlan":
      return stringValue(raw.plan_summary) || stringValue(raw.plan) || "Review the proposed plan.";
    case "question":
      return stringValue(raw.question_prompt) || "Answer the agent question.";
    default:
      return stringValue(raw.text) || stringValue(raw.reason) || stringValue(raw.cwd) || "";
  }
}

function compareLatestFirst(lhs: FeedItem, rhs: FeedItem): number {
  const lhsTime = lhs.createdAt?.getTime() ?? 0;
  const rhsTime = rhs.createdAt?.getTime() ?? 0;
  if (lhsTime !== rhsTime) {
    return rhsTime - lhsTime;
  }
  return rhs.id.localeCompare(lhs.id);
}

function kindLabel(kind: string): string {
  switch (kind) {
    case "permissionRequest":
      return "permission";
    case "exitPlan":
      return "plan";
    case "question":
      return "question";
    default:
      return kind;
  }
}

function statusColorFor(status: string): string {
  switch (status) {
    case "pending":
      return theme.pending;
    case "resolved":
      return theme.success;
    case "expired":
      return theme.textMuted;
    default:
      return theme.danger;
  }
}

function sourceInitial(source: string): string {
  return (source.trim()[0] ?? "?").toUpperCase();
}

function relativeTime(date: Date | undefined): string {
  if (!date) {
    return "";
  }
  const seconds = Math.max(0, Math.floor((Date.now() - date.getTime()) / 1_000));
  if (seconds < 60) {
    return `${seconds}s`;
  }
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) {
    return `${minutes}m`;
  }
  const hours = Math.floor(minutes / 60);
  if (hours < 24) {
    return `${hours}h`;
  }
  return `${Math.floor(hours / 24)}d`;
}

function wrapText(text: string, width: number, maxLines: number): string[] {
  const normalizedWidth = Math.max(1, width);
  const normalized = text.replace(/\s+/g, " ").trim();
  if (!normalized) {
    return [];
  }
  const words = normalized.split(" ");
  const lines: string[] = [];
  let current = "";
  for (const word of words) {
    if (word.length > normalizedWidth) {
      if (current) {
        lines.push(current);
        current = "";
      }
      for (let index = 0; index < word.length; index += normalizedWidth) {
        lines.push(word.slice(index, index + normalizedWidth));
        if (lines.length >= maxLines) {
          break;
        }
      }
      if (lines.length >= maxLines) {
        break;
      }
      continue;
    }
    if (!current) {
      current = word;
      continue;
    }
    if (current.length + 1 + word.length <= normalizedWidth) {
      current = `${current} ${word}`;
      continue;
    }
    lines.push(current);
    current = word;
    if (lines.length >= maxLines) {
      break;
    }
  }
  if (lines.length < maxLines && current) {
    lines.push(current);
  }
  if (lines.length > maxLines) {
    return lines.slice(0, maxLines);
  }
  if (lines.length === maxLines && words.join(" ").length > lines.join(" ").length) {
    lines[lines.length - 1] = `${clamp(lines[lines.length - 1], Math.max(4, normalizedWidth - 4))} ...`;
  }
  return lines;
}

function clamp(value: string, maxLength: number): string {
  if (value.length <= maxLength) {
    return value;
  }
  return `${value.slice(0, Math.max(0, maxLength - 3))}...`;
}

function cleanText(value: string): string {
  return value.replace(/[\u0000-\u001F\u007F]/g, " ").replace(/\s+/g, " ").trim();
}

function stringValue(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed || undefined;
}

function dateValue(value: unknown): Date | undefined {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    return new Date(value > 10_000_000_000 ? value : value * 1_000);
  }
  if (typeof value === "string" && value.trim()) {
    const numeric = Number(value);
    if (Number.isFinite(numeric) && numeric > 0) {
      return dateValue(numeric);
    }
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? undefined : date;
  }
  return undefined;
}

function isKey(key: KeyEvent, ...names: string[]): boolean {
  if (names.includes(key.name) || names.includes(key.sequence) || names.includes(key.raw)) {
    return true;
  }
  if ((names.includes("return") || names.includes("enter")) &&
      (key.sequence === "\r" || key.sequence === "\n" || key.raw === "\r" || key.raw === "\n")) {
    return true;
  }
  return false;
}

function isCtrlC(key: KeyEvent): boolean {
  return (key.ctrl && isKey(key, "c")) || key.sequence === "\u0003" || key.raw === "\u0003";
}

function actionForKey(key: KeyEvent): string | undefined {
  if (isKey(key, "d")) {
    return "deny";
  }
  if (isKey(key, "a")) {
    return "always";
  }
  if (isKey(key, "l")) {
    return "all";
  }
  if (isKey(key, "b")) {
    return "bypass";
  }
  if (isKey(key, "m")) {
    return "manual";
  }
  if (isKey(key, "u")) {
    return "ultraplan";
  }
  const keyText = key.sequence || key.name || key.raw;
  if (/^[1-9]$/.test(keyText)) {
    return `option:${keyText}`;
  }
  if (keyText === "0") {
    return "option:10";
  }
  return undefined;
}

function permissionMode(action: string): string {
  switch (action) {
    case "always":
      return "always";
    case "all":
      return "all";
    case "bypass":
      return "bypass";
    case "deny":
      return "deny";
    default:
      return "once";
  }
}

function planMode(action: string, defaultMode: string | undefined): string {
  switch (action) {
    case "always":
      return "autoAccept";
    case "manual":
      return "manual";
    case "ultraplan":
      return "ultraplan";
    case "bypass":
      return "bypassPermissions";
    case "deny":
      return "deny";
    default:
      return defaultMode || "manual";
  }
}

function questionOption(options: FeedOption[], action: string): FeedOption | undefined {
  if (action.startsWith("option:")) {
    const index = Number(action.slice("option:".length)) - 1;
    return options[index];
  }
  return options[0];
}

function formatError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function cardId(item: FeedItem): string {
  return `feed-card-${item.id.replace(/[^a-zA-Z0-9_-]/g, "-")}`;
}

function writeReadyMarker(stage: string, details: Record<string, string> = {}): void {
  const markerPath = process.env.CMUX_FEED_TUI_READY_PATH?.trim();
  if (!markerPath) {
    return;
  }
  try {
    const payload = JSON.stringify({
      stage,
      pid: String(process.pid),
      time: String(Date.now() / 1000),
      tui: process.env.CMUX_FEED_TUI_PATH ?? "opentui",
      ...details,
    });
    mkdirSync(dirname(markerPath), { recursive: true });
    writeFileSync(markerPath, `${payload}\n`, "utf8");
  } catch {
    // Best-effort test marker only.
  }
}

async function main() {
  const socketPath = process.env.CMUX_SOCKET_PATH;
  if (!socketPath) {
    throw new Error("CMUX_SOCKET_PATH is required.");
  }

  const renderer = await createCliRenderer({
    exitOnCtrlC: false,
    screenMode: "alternate-screen",
    useMouse: true,
    autoFocus: true,
    targetFps: 30,
  });
  const app = new FeedApp(renderer, new FeedSocketClient(socketPath, process.env.CMUX_SOCKET_PASSWORD));

  const shutdown = () => {
    app.stop();
    process.exit(0);
  };
  process.once("SIGTERM", shutdown);
  process.once("SIGINT", shutdown);

  try {
    await app.start();
  } catch (error) {
    renderer.destroy();
    throw error;
  }
}

void main().catch((error) => {
  console.error(`cmux feed tui failed: ${formatError(error)}`);
  process.exit(1);
});
