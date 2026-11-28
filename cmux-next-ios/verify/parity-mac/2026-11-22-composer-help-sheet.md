# The `/` list says what each command and skill does on every row, and `/help` opens one searchable sheet of the composer's commands, skills and keys; a pick writes `/name ` into the prompt (`SlashMenu.tsx`, `HelpSheet.tsx`, `composerHelp.ts`, 2026-11-22)

- Section: Composer
- Mac sends: composer `/` list; `/help`
- Phone: the composer's `/` rows; `/help`
- State: works (code-checked)
- Notes: The phone's `/` rows already showed each description (`ChatComposer.slashSuggestions`). `/help` is a `CmuxSlashCommand`: a searchable sheet (`ComposerHelpSheet`) over the same merged list the `/` rows read (`CmuxSlashCommand.merged`), every word must match, a tap writes `/name `. A terminal's Chat face offers only `/status` there, as in its `/` rows. The Mac's Keys group is a hardware keyboard's and is left out on the phone. No new trust: it only fills the draft.
