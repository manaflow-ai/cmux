import { useEffect } from "react";
import { MarkdownCodeBlock } from "../ChatMarkdown";
import { agentChatText } from "../i18n";

export function FileDiffView({ diff, error, onRequest }: {
  diff?: string;
  error?: string;
  onRequest: () => void;
}) {
  // An expanded diff can survive history replacement after reconnect. Ask
  // again when its cache is cleared; the session deduplicates pending loads.
  useEffect(() => {
    if (diff === undefined && error === undefined) onRequest();
  }, [diff, error, onRequest]);

  if (error !== undefined) {
    return <div className="diff-error" role="status">
      <span>{error}</span>
      <button type="button" className="diff-retry" onClick={onRequest}>{agentChatText("retryDiff")}</button>
    </div>;
  }
  if (diff === undefined) return <div className="diff-loading" role="status">{agentChatText("loadingDiff")}</div>;
  return <MarkdownCodeBlock code={diff} lang="diff" />;
}
