# Review

Run an adversarial review of the current change using the repository's cmux review skill.

Read and follow:

`skills/cmux-review/SKILL.md`

Use the current task/conversation as the change intent when available. Default to reviewing the current working tree against `origin/main` (or the repository default branch when origin/main is unavailable).

Produce the review brief first. Keep independent discovery passes independent, challenge only credible findings, gather executable evidence where practical, and keep the human-facing report small.

Persist a local review receipt under the Git metadata path described by the skill. Do not commit the receipt or scratch verification artifacts.

Do not repair findings unless the user asks for repair or the current task explicitly includes fixing review findings.
