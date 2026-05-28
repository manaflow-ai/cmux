export type PromptMentionText = {
  displayName?: string;
  kind: "at" | "agent" | "skill";
  label?: string;
  name: string;
  path: string;
};

export function promptMentionMarkdown(mention: PromptMentionText): string {
  switch (mention.kind) {
    case "at":
      return markdownLink(mention.label ?? mention.name, mention.path);
    case "agent":
      return markdownLink(`@${mention.displayName || mention.name}`, mention.path);
    case "skill":
      return markdownLink(`$${mention.name}`, mention.path);
  }
}

function markdownLink(label: string, destination: string): string {
  return `[${escapeMarkdownLabel(label)}](${escapeMarkdownDestination(destination)})`;
}

function escapeMarkdownLabel(label: string): string {
  return label.replace(/([\\[\]])/g, "\\$1");
}

function escapeMarkdownDestination(destination: string): string {
  return encodeURI(destination).replace(/([()\\])/g, "\\$1");
}
