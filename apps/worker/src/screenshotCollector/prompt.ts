interface PromptConfig {
  baseBranch: string;
  mergeBase: string;
  formattedFileList: string;
  prDescription: string | null;
  /** Additional context/notes for the screenshot agent (e.g., auth instructions, specific pages) */
  screenshotAgentContext: string | null;
}

export function formatFileList(files: readonly string[]): string {
  return files.join("\n");
}

export function buildScreenshotPrompt({
  baseBranch,
  mergeBase,
  formattedFileList,
  prDescription,
  screenshotAgentContext,
}: PromptConfig): string {
  const sections = [
    "You are a release engineer evaluating repository changes to determine if screenshots need refreshing before sharing updates.",
    `Repository base branch: ${baseBranch}`,
    `Merge base commit: ${mergeBase}`,
    `<pull_request_description>\n${prDescription ?? "<none provided>"}\n</pull_request_description>`,
    `<changed_files>\n${formattedFileList}\n</changed_files>`,
  ];

  // Add additional context if provided
  if (screenshotAgentContext && screenshotAgentContext.trim().length > 0) {
    sections.push(
      `<additional_context>\nThe environment owner provided the following notes/instructions:\n${screenshotAgentContext}\n</additional_context>`
    );
  }

  sections.push(
    [
      "Return a JSON object matching { hasUiChanges: boolean; uiChangesToScreenshotInstructions: string }.",
      "Set hasUiChanges to true when the listed files imply UI changes that should be captured.",
      "If hasUiChanges is true, describe exactly which UI flows or screens to capture in uiChangesToScreenshotInstructions.",
      "Include the http urls that an agent should first navigate to in order to capture the screenshots.",
      "Ensure that you've explored the codebase sufficiently to understand which port and path the agent should navigate to in order to capture the screenshots.",
      'If false, respond with "None".',
    ].join("\n")
  );

  return sections.join("\n\n");
}
