"use client";

import clsx from "clsx";
import { Bot, User, CheckCircle2 } from "lucide-react";
import type { OnboardingMessage } from "./types";

interface ChatMessageProps {
  message: OnboardingMessage;
}

export function ChatMessage({ message }: ChatMessageProps) {
  const isAssistant = message.role === "assistant";
  const isUser = message.role === "user";

  if (message.type === "action") {
    return (
      <div className="flex items-center gap-2 py-2 px-3 rounded-lg bg-emerald-500/10 border border-emerald-500/20 text-emerald-600 dark:text-emerald-400 text-sm">
        <CheckCircle2 className="h-4 w-4 shrink-0" />
        <span>{message.content}</span>
      </div>
    );
  }

  return (
    <div
      className={clsx(
        "flex gap-3",
        isUser && "flex-row-reverse"
      )}
    >
      <div
        className={clsx(
          "h-8 w-8 rounded-full flex items-center justify-center shrink-0",
          isAssistant && "bg-gradient-to-br from-orange-500 to-amber-600",
          isUser && "bg-neutral-200 dark:bg-neutral-800"
        )}
      >
        {isAssistant ? (
          <Bot className="h-4 w-4 text-white" />
        ) : (
          <User className="h-4 w-4 text-neutral-600 dark:text-neutral-400" />
        )}
      </div>
      <div
        className={clsx(
          "flex-1 rounded-2xl px-4 py-3 text-sm leading-relaxed max-w-[85%]",
          isAssistant && "bg-neutral-100 dark:bg-neutral-900 text-neutral-800 dark:text-neutral-200",
          isUser && "bg-neutral-900 dark:bg-neutral-100 text-white dark:text-neutral-900 ml-auto"
        )}
      >
        {message.content.split("\n").map((line, i) => (
          <p key={i} className={i > 0 ? "mt-2" : ""}>
            {line}
          </p>
        ))}
      </div>
    </div>
  );
}
