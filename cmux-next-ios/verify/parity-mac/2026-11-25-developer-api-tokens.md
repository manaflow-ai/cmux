# Settings > Developer: API tokens (personal, team and GitHub Actions)

- Section: Settings > Developer
- Mac sends: `cmux.settings.tokens.*` page ops, relayed to the bundled `cmux token ... --json`
- Phone: no credential minting or revocation surface
- State: not from a phone
- Notes: Leo 2026-11-25: "Convienient beats all. Just make good ui for it so people flow." Minting or revoking account credentials from the phone is a new trust class; why it stays off is recorded in SECURITY.md, "Not from a phone: API tokens". The Mac page provides personal tokens, team tokens for team admins and GitHub Actions repository rules.
