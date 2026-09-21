# Writing style

For CMUX issues, RFCs, pull requests, and progress updates. This guides prose; existing engineering, review, and approval requirements still apply.

## Make the point easy to find

- Lead with the concrete problem and resulting behavior. Name what a person or API caller can do after the change.
- Use familiar words and precise verbs. “Expose stable surface IDs in catalog reads” is clearer than “expose persisted identity joins.”
- Explain the mechanism needed to assess the change. Link deeper design and implementation detail.
- Scale the explanation to the work. A small fix usually needs one or two paragraphs plus validation. Aim for one screen for a proposal's main argument; link supporting detail when needed.
- Use headings, bullets, and tables when they help scanning. Remove empty sections and template prompts where the template permits; retain required evidence and checklists.
- State a material limitation once, beside the claim it qualifies. Cut repeated summaries, coordination history, and inventories of unrelated things left unchanged.

## Make the evidence trustworthy

Say what ran, what passed, and what that establishes. Added tests, executed tests, compilation, and live behavior are different evidence. A green workflow with skipped tests does not establish that those tests ran.

Keep the description current when scope or implementation changes. Replace obsolete pending status; preserve earlier attempts only when they explain a decision. Keep exact commit/build references where they identify the evidence being cited.

Bound measurements to the operation and conditions observed. A faster app-copy step does not establish a faster full build.

## Useful shapes

- **PR:** problem → resulting behavior → relevant validation and remaining gap.
- **RFC:** user outcome → foundations → smallest next slice → observable acceptance condition. Distinguish what exists, what a dependency enables, and what still needs implementation.
- **Update:** what completed → current blocker, if any → next action. Usually one to three sentences.

Example PR opening:

> In a checkout, the settings helper rejects valid sidebar keys that the installed helper accepts. Both now use the same schema-backed path list, with a regression that detects drift.

Recent examples worth borrowing from: [#13156](https://github.com/manaflow-ai/cmux/pull/13156) for a concrete failure and observed result, [#13240](https://github.com/manaflow-ai/cmux/pull/13240) for a bounded fix, and [#13241](https://github.com/manaflow-ai/cmux/pull/13241) for a carefully scoped performance claim.
