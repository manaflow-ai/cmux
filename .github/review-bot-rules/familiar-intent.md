# Familiar intent regions

An `@intent` marker with `stability=familiar` names a product region whose
defaults and behavior should remain recognizable. The marker's `owner` value
is the GitHub handle to mention.

When a pull request changes a hunk containing this marker, CodeRabbit and cubic
must post a warning and mention the owner unless the pull request body contains
a non-placeholder `Intent-Delta:` line. `Intent-Delta: none` is the template
placeholder and does not suppress the warning. This is advisory: it never
requests changes or blocks the pull request. The line should say `preserved`, `modified(...)`,
`retired(...)`, or `new(...)` so the owner can see the intended delta.
