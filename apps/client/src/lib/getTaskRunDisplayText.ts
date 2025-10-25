interface TaskRunDisplaySource {
  agentName?: string | null;
  summary?: string | null;
  prompt: string;
}

export function getTaskRunDisplayText(run: TaskRunDisplaySource): string {
  const agentLabel = run.agentName?.trim();
  if (agentLabel) {
    return agentLabel;
  }

  if (run.summary && run.summary.trim().length > 0) {
    return run.summary;
  }

  const prompt = run.prompt ?? "";
  if (prompt.length <= 50) {
    return prompt;
  }

  return `${prompt.substring(0, 50)}...`;
}

