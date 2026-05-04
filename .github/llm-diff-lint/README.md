# LLM Diff Lint

This lint runs one AI SDK request per provider per rule. Each request receives the complete PR diff plus one focused rule and returns JSON with `violated`, `severity`, `summary`, and findings.

The workflow uses `pull_request_target` and fetches the net PR diff with `gh pr diff`. It does not check out or execute PR code, which keeps repository secrets out of untrusted PR scripts.

Security boundaries:

- no `pull_request` trigger, so fork or branch PR code never runs with repository secrets
- manual `workflow_dispatch` accepts only a numeric PR number and still checks out the repository default branch
- checkout always uses the repository default branch
- `id-token: write` is scoped only to the Google Vertex job
- model input and model output are redacted before artifacts, annotations, and PR comments
- the GCP Workload Identity provider is restricted to `.github/workflows/llm-diff-lint.yml` on `main`

## Secrets And Variables

Required secret:

- `DEEPSEEK_API_KEY`

Optional secret:

- `AI_GATEWAY_API_KEY`, enables the Codex-backed `swift-architectural-rethink` rule through Vercel AI Gateway. Without this secret the job uploads a skipped result and does not block PRs.

Optional repository variables:

- `AI_GATEWAY_BASE_URL`, optional AI Gateway override
- `GCP_WORKLOAD_IDENTITY_PROVIDER`, defaults to the cmux GitHub Actions workload identity provider
- `GCP_SERVICE_ACCOUNT`, defaults to `cmux-vertex-ai@manaflow-437420.iam.gserviceaccount.com`
- `GOOGLE_VERTEX_PROJECT`, required for Gemini unless `GOOGLE_CLOUD_PROJECT` is set in the environment
- `GOOGLE_VERTEX_LOCATION`, defaults to `global`
- `LLM_DIFF_LINT_CODEX_MODEL`, defaults to `openai/gpt-5.3-codex`
- `LLM_DIFF_LINT_CODEX_REASONING_EFFORT`, defaults to `medium`
- `LLM_DIFF_LINT_CODEX_MAX_TOKENS`, defaults to `LLM_DIFF_LINT_MAX_TOKENS` or `8192`
- `LLM_DIFF_LINT_MAX_TOKENS`, defaults to `8192`
- `LLM_DIFF_LINT_RETRIES`, defaults to `0`
- `LLM_DIFF_LINT_THINKING`, defaults to `disabled` for DeepSeek
- `LLM_DIFF_LINT_MAX_DIFF_BYTES`, defaults to `5000000`
- `DEEPSEEK_BASE_URL`, optional DeepSeek override

The default provider matrix compares `deepseek-v4-pro` with `gemini-3-flash-preview` through Vertex AI. GitHub Actions authenticates to Vertex with OIDC workload identity and the `cmux-vertex-ai` service account. This avoids storing a long-lived GCP service account key.

The broader `swift-architectural-rethink` rule runs once on OpenAI Codex through AI Gateway with medium reasoning. It uses `openai/gpt-5.3-codex` by default because the rule asks for architecture judgment rather than narrow lint matching.

Use `LLM diff lint status` as the required branch-protection check.

## Local Development CLI

Run the same rule set locally with:

```bash
bun scripts/llm_diff_lint_all.ts --pr 3455 --profile gateway
```

The `gateway` profile uses one `AI_GATEWAY_API_KEY` for all local model calls:

- focused rules with `deepseek/deepseek-v4-pro`
- focused rules with `google/gemini-3-flash`
- the architecture rule with `openai/gpt-5.3-codex` and medium reasoning

The default `auto` profile uses gateway when `AI_GATEWAY_API_KEY` is present. If it is not present, it falls back to direct providers and runs the jobs with credentials available in the environment, skipping missing providers unless `--strict` is passed.

Useful options:

```bash
bun scripts/llm_diff_lint_all.ts --pr 3455 --env-file ~/.secrets/cmux.env
bun scripts/llm_diff_lint_all.ts --diff-file /tmp/pr.diff --profile gateway
bun scripts/llm_diff_lint_all.ts --pr 3455 --profile gateway --post-comment
bun scripts/llm_diff_lint_all.ts --pr 3455 --rule-set architecture
```

By default the CLI writes JSON artifacts and `comment.md` under `tmp/llm-diff-lint/<source>/` and prints the same comment body that the GitHub Action posts. `--post-comment` updates the PR issue comment through `scripts/llm_diff_lint_comment.py`.

For local Gemini runs, authenticate Application Default Credentials first:

```bash
gcloud auth application-default login
```

## Cost Model

Every provider/rule job sends the full diff plus one rule. Estimated input tokens are roughly:

```text
(diff bytes / 4 + rule tokens + prompt overhead) * provider count * rule count
```

The Codex architecture rule is one extra full-diff request when `AI_GATEWAY_API_KEY` is configured.

Current published prices as of 2026-05-02:

| Model | Input, cache miss | Input, cache hit | Output | Notes |
| --- | ---: | ---: | ---: | --- |
| `deepseek-v4-pro` | $1.74 / 1M | $0.0145 / 1M | $3.48 / 1M | DeepSeek official list price |
| `deepseek-v4-pro` | $0.435 / 1M | $0.003625 / 1M | $0.87 / 1M | DeepSeek promotional price through 2026-05-31 |
| `deepseek-v4-flash` | $0.14 / 1M | $0.0028 / 1M | $0.28 / 1M | Cheaper DeepSeek option, not current production model |
| `gemini-3-flash-preview` | $0.50 / 1M | provider dependent | $3.00 / 1M | Current latest Gemini Flash model used by this workflow |
| `gemini-2.5-flash-lite` | $0.10 / 1M | $0.01 / 1M | $0.40 / 1M | Cheapest generally available Gemini Flash-Lite model |
| `gpt-5.3-codex` | $1.75 / 1M | $0.175 / 1M | $14.00 / 1M | Codex architecture rule, medium reasoning |

Sources: [DeepSeek API pricing](https://api-docs.deepseek.com/quick_start/pricing), [Vertex AI Gemini pricing](https://cloud.google.com/vertex-ai/generative-ai/pricing), [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing), [OpenAI GPT-5.3-Codex model pricing](https://developers.openai.com/api/docs/models/gpt-5.3-codex), and [Vercel AI Gateway models](https://vercel.com/docs/ai-gateway/models-and-providers).

With cache misses, `deepseek-v4-pro` is currently cheaper than `gemini-3-flash-preview` during the DeepSeek promotion, but it is not cheaper than `gemini-2.5-flash-lite`. After the promotion, DeepSeek Pro is materially more expensive than both Flash options.

Assume cache miss for planning unless provider billing proves otherwise. PR diffs are usually unique, and this prompt is rule-first, so repeated rule calls should not rely on prefix-cache hits.

Retries repeat the full request and can multiply cost. Keep `LLM_DIFF_LINT_RETRIES=0` for required checks unless provider errors are transient and measured. One retry is reasonable for advisory shadow runs, but it did not fix repeated Gemini structured-output failures in the 2026-05-02 comparison.

## Rule Size

Keep each rule around 150 to 300 words. That is large enough to define failure cases and allowed cases, while small enough that the model focuses on one decision.

Avoid broad style guides. A good rule has:

- a narrow behavior class
- concrete failure cases
- concrete allowed cases
- one preferred fix direction

Do not include large code examples unless the syntax is ambiguous. Every extra rule token is paid once per PR per rule because each rule reads the full diff.

## Provider And Rule Split

The current split is 6 focused rules across 2 providers, plus 1 broad Codex architecture rule. That produces 13 jobs when `OPENAI_API_KEY` is configured, with the provider matrices capped at `max-parallel: 4`.

This keeps each LLM call independent and gives complete per-provider, per-rule status in GitHub checks. `fail-fast: false` lets all focused rules finish even when one fails.

Use this default for normal PR linting:

- 4 to 8 rules total
- 1 provider and 1 rule per LLM call
- 2 to 4 concurrent jobs, adjusted for provider rate limits

Add another rule only when it catches a distinct class of bug. If a rule starts mixing unrelated topics, split it. If two rules routinely flag the same lines, merge them.

Keep broad architecture rules out of the provider matrix unless they are cheap and stable. Run them once on a stronger coding model so they do not multiply cost across every provider comparison.
