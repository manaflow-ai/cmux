/** Keep a long cross-session message readable without letting one mail item
 * take over the transcript. The body remains available through the disclosure
 * control, so line count is the only presentation policy here. */
export const AGENT_MESSAGE_FOLD_LINES = 8;

export function agentMessageFoldedByDefault(body: string): boolean {
  return body.split(/\r?\n/).length > AGENT_MESSAGE_FOLD_LINES;
}

