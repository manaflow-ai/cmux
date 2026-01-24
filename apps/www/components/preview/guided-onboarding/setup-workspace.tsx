"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { Send, Sparkles, X } from "lucide-react";
import { SetupStep, type StepStatus } from "./setup-step";
import { SETUP_STEPS } from "./setup-steps";
import { OnboardingShell } from "../onboarding-shell";

interface SetupWorkspaceProps {
  repo: string;
  vscodeUrl: string;
  teamSlugOrId: string;
  onComplete: (config: Record<string, string>) => void;
  onFinishLater: () => void;
}

interface ChatMessage {
  id: string;
  role: "user" | "assistant";
  content: string;
}

export function SetupWorkspace({
  repo,
  vscodeUrl,
  teamSlugOrId: _teamSlugOrId,
  onComplete,
  onFinishLater,
}: SetupWorkspaceProps) {
  const repoName = repo.split("/").pop() || repo;

  // Initialize step values with defaults
  const [stepValues, setStepValues] = useState<Record<string, string>>(() => {
    const initial: Record<string, string> = {};
    for (const step of SETUP_STEPS) {
      initial[step.id] = step.defaultValue?.replace("{repo}", repoName) || "";
    }
    return initial;
  });

  const [currentStepIndex, setCurrentStepIndex] = useState(0);
  const [completedSteps, setCompletedSteps] = useState<Set<string>>(new Set());

  // Chat state
  const [chatOpen, setChatOpen] = useState(true);
  const [chatMessages, setChatMessages] = useState<ChatMessage[]>([
    {
      id: "1",
      role: "assistant",
      content:
        "Let's set up your environment together. Use the terminal on the right to run each step, and I'll help adjust commands as needed.\n\nTell me where you'd like to start.",
    },
  ]);
  const [chatInput, setChatInput] = useState("I'm ready. Let's start with step 1.");
  const [isStreaming, setIsStreaming] = useState(false);
  const chatEndRef = useRef<HTMLDivElement>(null);

  // Auto-scroll chat
  useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [chatMessages]);

  const getStepStatus = (stepId: string, index: number): StepStatus => {
    if (completedSteps.has(stepId)) return "completed";
    if (index === currentStepIndex) return "current";
    return "pending";
  };

  const handleStepChange = useCallback((stepId: string, value: string) => {
    setStepValues((prev) => ({ ...prev, [stepId]: value }));
  }, []);

  const handleVerifyStep = useCallback(async (stepId: string) => {
    // Mark step as completed and move to next
    setCompletedSteps((prev) => new Set([...prev, stepId]));
    const stepIndex = SETUP_STEPS.findIndex((s) => s.id === stepId);
    if (stepIndex < SETUP_STEPS.length - 1) {
      setCurrentStepIndex(stepIndex + 1);
    }
  }, []);

  const handleSendMessage = useCallback(async () => {
    const trimmed = chatInput.trim();
    if (!trimmed || isStreaming) return;

    const userMessage: ChatMessage = {
      id: Date.now().toString(),
      role: "user",
      content: trimmed,
    };
    setChatMessages((prev) => [...prev, userMessage]);
    setChatInput("");
    setIsStreaming(true);

    // Call the chat API
    try {
      const response = await fetch("/api/onboarding/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "include",
        body: JSON.stringify({
          messages: [
            ...chatMessages.map((m) => ({ role: m.role, content: m.content })),
            { role: "user", content: trimmed },
          ],
          step: SETUP_STEPS[currentStepIndex]?.id,
          repo,
        }),
      });

      if (!response.ok) throw new Error("Chat failed");

      const reader = response.body?.getReader();
      if (!reader) throw new Error("No reader");

      const assistantId = (Date.now() + 1).toString();
      setChatMessages((prev) => [...prev, { id: assistantId, role: "assistant", content: "" }]);

      const decoder = new TextDecoder();
      let fullContent = "";
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() || "";

        for (const line of lines) {
          if (line.startsWith("data: ")) {
            const data = line.slice(6);
            if (data === "[DONE]") continue;
            try {
              const parsed = JSON.parse(data);
              if (parsed.type === "content_block_delta" && parsed.delta?.text) {
                fullContent += parsed.delta.text;
                setChatMessages((prev) =>
                  prev.map((m) => (m.id === assistantId ? { ...m, content: fullContent } : m))
                );
              }
            } catch (error) {
              console.error("[guided-onboarding] Failed to parse chat stream chunk", error);
            }
          }
        }
      }
    } catch (err) {
      console.error("Chat error:", err);
      setChatMessages((prev) => [
        ...prev,
        {
          id: (Date.now() + 1).toString(),
          role: "assistant",
          content: "I'm here to help with setup. What would you like to configure?",
        },
      ]);
    } finally {
      setIsStreaming(false);
    }
  }, [chatInput, isStreaming, chatMessages, currentStepIndex, repo]);

  const handleFinishSetup = () => {
    onComplete(stepValues);
  };

  const completedCount = completedSteps.size;

  return (
    <OnboardingShell
      sidebarHeader={
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-sm font-medium text-neutral-900 dark:text-neutral-100">Repository setup</h2>
            <p className="text-xs text-neutral-500 dark:text-neutral-400 mt-1">Configure {repoName}</p>
          </div>
          <span className="text-xs text-neutral-500 dark:text-neutral-400">
            {completedCount}/{SETUP_STEPS.length} steps
          </span>
        </div>
      }
      sidebarBody={
        <div className="flex flex-col h-full">
          <div className="px-4 pt-4">
            <div className="rounded-lg border border-neutral-200/70 dark:border-neutral-800 bg-white/90 dark:bg-neutral-900/40 px-3 py-2 text-xs text-neutral-600 dark:text-neutral-400">
              Run each step in the terminal and mark it done when ready.
            </div>
          </div>
          <div className="flex-1 overflow-y-auto mt-2">
            {SETUP_STEPS.map((step, index) => (
              <SetupStep
                key={step.id}
                step={step}
                status={getStepStatus(step.id, index)}
                index={index}
                value={stepValues[step.id] || ""}
                onChange={(v) => handleStepChange(step.id, v)}
                onVerify={() => handleVerifyStep(step.id)}
              />
            ))}
          </div>
        </div>
      }
      sidebarFooter={
        <div className="flex gap-2">
          <button
            onClick={handleFinishSetup}
            className="flex-1 px-4 py-2 text-sm font-medium bg-neutral-900 text-white hover:bg-neutral-800 dark:bg-neutral-200 dark:text-neutral-900 dark:hover:bg-neutral-100 rounded transition"
          >
            Finish setup
          </button>
          <button
            onClick={onFinishLater}
            className="flex-1 px-4 py-2 text-sm font-medium bg-neutral-100 hover:bg-neutral-200 text-neutral-700 dark:bg-neutral-900 dark:text-neutral-200 dark:hover:bg-neutral-800 rounded transition"
          >
            Finish later
          </button>
        </div>
      }
      mainHeader={
        <>
          <div className="flex items-center gap-2 text-xs text-neutral-500 dark:text-neutral-400">
            <span className="inline-flex h-2 w-2 rounded-full bg-emerald-400" />
            Environment ready
            <span className="text-neutral-300 dark:text-neutral-700">•</span>
            <span className="text-neutral-500 dark:text-neutral-400">{repoName}</span>
          </div>
          <div className="flex items-center gap-2 text-xs text-neutral-500 dark:text-neutral-400">
            <span className="hidden sm:inline">PTY terminal connected</span>
            <span className="rounded-full border border-neutral-200/70 dark:border-neutral-800 px-2 py-0.5">
              Machine
            </span>
          </div>
        </>
      }
      mainBody={
        <div className="flex-1 flex flex-col lg:flex-row">
          <div className="flex-1 relative bg-neutral-100 dark:bg-neutral-900/40">
            <iframe
              src={vscodeUrl}
              className="absolute inset-0 w-full h-full border-0"
              allow="clipboard-read; clipboard-write"
            />

            {!chatOpen && (
              <>
                <button
                  onClick={() => setChatOpen(true)}
                  className="absolute bottom-4 right-4 flex items-center gap-2 px-4 py-2 bg-neutral-900 text-white dark:bg-neutral-200 dark:text-neutral-900 rounded-full text-sm shadow-lg hover:bg-neutral-800 dark:hover:bg-neutral-100 transition"
                >
                  <Sparkles className="w-4 h-4 text-amber-300 dark:text-amber-500" />
                  <span>Setup assistant</span>
                </button>
                <div className="absolute bottom-4 right-44 text-xs text-neutral-500 dark:text-neutral-400 hidden sm:block">
                  ⌘K to generate a command
                </div>
              </>
            )}
          </div>

          {chatOpen && (
            <div className="w-full lg:w-[360px] border-t border-neutral-200/70 dark:border-neutral-800 lg:border-t-0 lg:border-l bg-neutral-50 dark:bg-neutral-950/70 flex flex-col">
              <div className="flex items-center justify-between px-4 py-3 border-b border-neutral-200/70 dark:border-neutral-800">
                <div className="flex items-center gap-2">
                  <Sparkles className="w-4 h-4 text-amber-500" />
                  <div>
                    <p className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                      Setup assistant
                    </p>
                    <p className="text-[11px] text-neutral-500 dark:text-neutral-400">
                      Ask for commands or troubleshooting
                    </p>
                  </div>
                </div>
                <button
                  onClick={() => setChatOpen(false)}
                  className="text-neutral-400 hover:text-neutral-600 dark:hover:text-neutral-200 transition"
                >
                  <X className="w-4 h-4" />
                </button>
              </div>

              <div className="flex-1 overflow-y-auto p-4 space-y-3">
                {chatMessages.map((msg) => (
                  <div
                    key={msg.id}
                    className={`flex ${msg.role === "user" ? "justify-end" : "justify-start"}`}
                  >
                    <div
                      className={`max-w-[85%] rounded-2xl px-3 py-2 text-sm whitespace-pre-line ${
                        msg.role === "user"
                          ? "bg-neutral-900 text-white dark:bg-neutral-200 dark:text-neutral-900"
                          : "bg-white text-neutral-800 dark:bg-neutral-900/80 dark:text-neutral-200 border border-neutral-200/70 dark:border-neutral-800"
                      }`}
                    >
                      {msg.content || <span className="text-neutral-400">...</span>}
                    </div>
                  </div>
                ))}
                <div ref={chatEndRef} />
              </div>

              <div className="border-t border-neutral-200/70 dark:border-neutral-800 p-3">
                <div className="flex gap-2">
                  <input
                    type="text"
                    value={chatInput}
                    onChange={(e) => setChatInput(e.target.value)}
                    onKeyDown={(e) => e.key === "Enter" && !e.shiftKey && handleSendMessage()}
                    placeholder="Ask for help with setup..."
                    disabled={isStreaming}
                    className="flex-1 rounded-lg border border-neutral-200 dark:border-neutral-800 bg-white dark:bg-neutral-900 px-3 py-2 text-sm text-neutral-800 dark:text-neutral-100 placeholder:text-neutral-400 dark:placeholder:text-neutral-500 focus:outline-none focus:border-neutral-400 dark:focus:border-neutral-600 disabled:opacity-50"
                  />
                  <button
                    onClick={handleSendMessage}
                    disabled={isStreaming || !chatInput.trim()}
                    className="px-3 py-2 rounded-lg bg-neutral-900 text-white dark:bg-neutral-200 dark:text-neutral-900 hover:bg-neutral-800 dark:hover:bg-neutral-100 transition disabled:opacity-50 disabled:cursor-not-allowed"
                  >
                    <Send className="w-4 h-4" />
                  </button>
                </div>
                <p className="mt-2 text-[11px] text-neutral-500 dark:text-neutral-400">
                  Tip: Use the terminal in VS Code to run each step.
                </p>
              </div>
            </div>
          )}
        </div>
      }
    />
  );
}
