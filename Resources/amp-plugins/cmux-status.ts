// @i-know-the-amp-plugin-api-is-wip-and-very-experimental-right-now
import type { PluginAPI } from "@ampcode/plugin";

const STATUS_KEY = "amp";
const LOG_SOURCE = "amp";

function toolLabel(tool: string): string {
  switch (tool) {
    case "Read":
      return "reading";
    case "edit_file":
    case "create_file":
      return "editing";
    case "Bash":
      return "running cmd";
    case "Grep":
    case "finder":
    case "glob":
      return "searching";
    case "Task":
      return "subagent";
    case "oracle":
      return "consulting oracle";
    case "web_search":
    case "read_web_page":
      return "browsing";
    case "mermaid":
      return "diagramming";
    case "handoff":
      return "handing off";
    case "skill":
      return "loading skill";
    default:
      return tool;
  }
}

function toolIcon(tool: string): string {
  switch (tool) {
    case "Read":
      return "eye";
    case "edit_file":
    case "create_file":
      return "pencil";
    case "Bash":
      return "terminal";
    case "Grep":
    case "finder":
    case "glob":
      return "magnifyingglass";
    case "Task":
      return "person.2";
    case "oracle":
      return "sparkles";
    case "web_search":
    case "read_web_page":
      return "globe";
    default:
      return "hammer";
  }
}

export default function (amp: PluginAPI) {
  const pid = process.env.CMUX_AMP_PID;

  const setStatus = async (label: string, icon: string, color: string) => {
    try {
      if (pid) {
        await amp.$`cmux set-status ${STATUS_KEY} ${label} --icon ${icon} --color ${color} --pid ${pid}`;
      } else {
        await amp.$`cmux set-status ${STATUS_KEY} ${label} --icon ${icon} --color ${color}`;
      }
    } catch {}
  };

  const clearStatus = async () => {
    try {
      await amp.$`cmux clear-status ${STATUS_KEY}`;
    } catch {}
  };

  const log = async (message: string, level: string = "info") => {
    try {
      await amp.$`cmux log --level ${level} --source ${LOG_SOURCE} -- ${message}`;
    } catch {}
  };

  const cleanup = () => {
    clearStatus();
  };

  process.on("SIGINT", cleanup);
  process.on("SIGTERM", cleanup);

  amp.on("session.start", async () => {
    await setStatus("idle", "circle", "adb5bd");
  });

  amp.on("agent.start", async () => {
    await setStatus("thinking", "brain", "ffffff");
    await log("prompt received", "info");
  });

  amp.on("tool.call", async (event) => {
    const label = toolLabel(event.tool);
    const icon = toolIcon(event.tool);
    await setStatus(label, icon, "ffd700");
    return { action: "allow" as const };
  });

  amp.on("tool.result", async (event) => {
    if (event.status === "error") {
      await log(`${event.tool} failed`, "error");
    }
  });

  amp.on("agent.end", async (event) => {
    switch (event.status) {
      case "done":
        await setStatus("done", "checkmark.circle", "50fa7b");
        await log("turn complete", "success");
        break;
      case "error":
        await setStatus("error", "xmark.circle", "ff5555");
        await log("turn errored", "error");
        break;
      case "interrupted":
        await setStatus("interrupted", "pause.circle", "ffb86c");
        await log("turn interrupted", "warning");
        break;
    }
  });
}
