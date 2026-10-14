# Familiar intent regions

An `@intent` marker with `stability=familiar` names a product region whose
defaults and behavior should remain recognizable. The marker's `owner` value
is the GitHub handle to mention.

When a pull request changes a hunk containing this marker, CodeRabbit and cubic
must post a warning and mention the owner unless the pull request says what
happens to that region. Nothing is required of the author: the PR template has
no field for this. CodeRabbit and cubic infer the intent from the description
and the diff, and warn only when they can't tell whether the region's familiar
behavior is kept. An optional `Intent-Delta:` line (`preserved`,
`modified(...)`, `retired(...)` or `new(...)`) settles it; a missing line or
`Intent-Delta: none` counts as no stated delta. This is advisory: it never
requests changes or blocks the pull request.
