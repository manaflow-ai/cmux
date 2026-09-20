# Writing style

Read this before drafting or revising top-level issue and PR descriptions, RFCs, or progress updates.

This guides prose; engineering, review, and approval requirements still apply.

## Say what changes

Lead with the concrete problem and resulting behavior. Name what a person or API caller can do after the change, then explain the mechanism needed to assess it.

Use familiar words and precise verbs. Write as you'd speak to a technically literate colleague; contractions are welcome. Preserve useful wording when editing instead of imposing a new cadence.

A small fix often needs a paragraph plus validation. Use headings, lists, code, or diagrams when they help readers understand, not to fill a template. Link deeper evidence instead of narrating the investigation. Examples and suggested lengths aren't quotas.

State a material limitation once, beside the claim it qualifies. Cut repeated summaries, coordination history, stock transitions, and inventories of unrelated things left unchanged. End when the point lands.

## Say what the evidence establishes

Say what ran, what passed, and what that proves. Added tests, executed tests, compilation, and live behavior differ; skipped tests don't establish a pass.

Keep the description current when the implementation changes. Include exact commit or build references where they identify the evidence. Keep earlier attempts only when they explain a decision.

Keep measurements tied to what was observed. A faster app-copy step doesn't establish a faster full build.

## Before publishing

Read the description as a reviewer who hasn't seen the conversation. Can they understand the change and assess its evidence? Remove anything that repeats an answer they've already received.

Example opening:

> In a checkout, the settings helper rejects valid sidebar keys that the installed helper accepts. Both now use the same schema-backed path list, with a regression that detects drift.
