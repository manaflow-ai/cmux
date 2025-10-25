Important scripts for manual cleanup


```bash
bun run ./scripts/prune-convex-preview-deployments.ts --github-repo manaflow-ai/cmux --min-age-days 3 --exclude adorable-wombat-701 polite-canary-804 famous-camel-162
bun run ./scripts/morph-pause-old-active-instances.ts
```
