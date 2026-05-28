import type { AgentSessionAttachment } from "./types";

export function promptTextWithAttachments(input: string, attachments: AgentSessionAttachment[]): string {
  const attachmentText = attachments
    .map((attachment) => `[${escapeMarkdownLabel(attachment.label)}](${escapeMarkdownDestination(attachment.path)})`)
    .join(" ");
  if (!attachmentText) {
    return input;
  }
  return input.trim().length > 0 ? `${attachmentText}\n\n${input}` : attachmentText;
}

function escapeMarkdownLabel(label: string): string {
  return label.replace(/([\\[\]])/g, "\\$1");
}

function escapeMarkdownDestination(destination: string): string {
  return encodeURI(destination).replace(/([\\()])/g, "\\$1");
}
