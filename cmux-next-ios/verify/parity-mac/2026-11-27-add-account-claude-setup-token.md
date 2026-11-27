# Add account: a Claude setup token for chats on this Mac (`claude setup-token`, pasted)

- Section: Agents
- Mac sends: page `account.add {kind: claude-token, family: claude, name, secret}`; the app strips the token's whitespace, checks it, stores it in the login Keychain and calls acpmux `_acpmux/connections/claude_token.add {secret: keychain:…, label}`; a local Claude spawn on that route gets `CLAUDE_CODE_OAUTH_TOKEN` (acpmux `routes::env_for_on`).
- Phone: none; the phone has no Add account (a remote chat's `account.add` is refused on the Mac too)
- State: not from a phone
- Notes: cmux#59852. The token goes to the Mac's Keychain and the Mac's acpmux routes, which a phone does not write (SECURITY.md: no local credential writes from a peer). A Cloud chat on the phone already runs on the same connection once it is added on the Mac.
