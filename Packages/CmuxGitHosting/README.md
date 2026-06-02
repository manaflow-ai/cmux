# CmuxGitHosting

A general, user-configurable git-hosting provider layer for cmux's sidebar pull
request poller. It replaces the old "github.com only" hardcoding with a declarative
provider system that works for GitHub (including GitHub Enterprise Server), GitLab
(including self-hosted), Bitbucket Cloud, and **any** other host a user describes in
`~/.config/cmux/cmux.json`.

## How it fits together

```
git remote URL ──► GitRemoteReference        (host + owner/repo, host preserved)
host           ──► GitHostingResolver         (config rule → preset → gh discovery)
                     └─► GitHostingRequestPlan (build URLRequests, parse responses)
                            └─► [HostedPullRequest]
```

The poller keeps its own `URLSession`, caching, jitter, and timers. This package only
owns the four host-specific seams: parse the remote, resolve the provider + token,
build the request, and parse the response.

## Resolution order

For each host, `GitHostingResolver`:

1. Uses the first matching `gitHosting.providers` rule (exact host or `*.suffix`).
2. Otherwise auto-detects github.com / gitlab.com / bitbucket.org.
3. Otherwise asks `gh auth token --hostname <host>`; a token means it is a GitHub
   Enterprise Server instance (`/api/v3/`). This is self-configuring, no allowlist.
4. Otherwise the host is not pollable and is skipped.

## Configuring a host

```jsonc
"gitHosting": {
  "providers": [
    // Reuse a preset, point it at a self-hosted instance:
    { "host": "gitlab.example.com", "preset": "gitlab",
      "apiBaseURL": "https://gitlab.example.com/api/v4/",
      "token": { "environment": ["MY_GITLAB_TOKEN"] } },

    // Describe a brand-new host from scratch:
    { "host": "git.internal",
      "spec": {
        "apiBaseURL": "https://{host}/api/v1/",
        "pullRequestsPath": "repos/{path}/pulls",
        "query": [{ "name": "state", "value": "all" }],
        "auth": { "scheme": "token", "token": { "environment": ["GITEA_TOKEN"] } },
        "response": {
          "number": "number", "url": "html_url", "state": "state",
          "mergedWhenPresent": "merged_at",
          "headRef": "head.ref", "baseRef": "base.ref",
          "stateMap": { "OPEN": "OPEN", "CLOSED": "CLOSED" }
        }
      } }
  ]
}
```

Template tokens available in URL/query fields: `{host}`, `{path}`, `{pathEncoded}`,
`{owner}`, `{name}`, and `{branch}` (branch filter only).

## Testing

Everything is injectable, so tests never touch the network or spawn a real process:

```swift
let resolver = GitHostingResolver(
    config: .default,
    environment: ["GH_TOKEN": "test-token"],
    commandRunner: RecordingCommandRunner(),   // a fake CommandRunning
    workingDirectory: "/tmp"
)
let plan = try #require(await resolver.resolvePlan(forHost: "github.com"))
let request = plan.repositoryRequest(for: reference, page: 1)
let prs = plan.parsePullRequests(from: responseData)
```

Response parsing is pure (`Data` → `[HostedPullRequest]`), so provider behavior is
verified against recorded JSON fixtures rather than live APIs.
