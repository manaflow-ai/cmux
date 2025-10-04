# GitHub Actions Sync Implementation

This implementation adds GitHub Actions workflow run synchronization from webhooks to Convex tables.

## What was implemented:

### 1. Database Schema (`packages/convex/convex/schema.ts`)

- Added `githubWorkflowRuns` table to store GitHub Actions workflow run data
- Includes fields for run metadata, status, conclusion, timing, actor info, and PR associations
- Proper indexes for efficient querying by team, repo, workflow, and run ID

### 2. Webhook Handler (`packages/convex/convex/github_webhook.ts`)

- Added support for `workflow_run` webhook events
- Processes workflow run data and stores it in Convex
- Maintains existing webhook security (HMAC signature verification)
- Acknowledges `workflow_job` events for future expansion

### 3. Core Functions (`packages/convex/convex/github_workflows.ts`)

- `upsertWorkflowRunFromWebhook`: Processes webhook payload and stores workflow run data
- `getWorkflowRuns`: Query workflow runs with filtering by team, repo, and workflow
- `getWorkflowRunsForPr`: Get workflow runs triggered by a specific PR
- `getWorkflowRunById`: Get a specific workflow run by ID
- `backfillWorkflowRuns`: Placeholder for historical data backfill

### 4. API Routes (`apps/www/lib/routes/github.workflows.route.ts`)

- `GET /api/integrations/github/workflow-runs`: List workflow runs with filtering
- `GET /api/integrations/github/workflow-runs/pr`: Get workflow runs for a specific PR
- Proper authentication and error handling
- OpenAPI documentation

### 5. Integration

- Added router to main Hono app
- Exported from routes index
- Follows existing patterns for GitHub integration

## Usage:

### Webhook Processing

The system automatically processes GitHub Actions workflow run webhooks and stores the data in Convex.

### API Endpoints

1. **Get Workflow Runs**

   ```
   GET /api/integrations/github/workflow-runs?team=<team>&repoFullName=<owner/repo>&limit=50
   ```

2. **Get Workflow Runs for PR**
   ```
   GET /api/integrations/github/workflow-runs/pr?team=<team>&repoFullName=<owner/repo>&prNumber=123
   ```

### Database Queries

```typescript
// Get workflow runs for a team
const runs = await convex.query(api.github_workflows.getWorkflowRuns, {
  teamId: "team-id",
  repoFullName: "owner/repo",
  limit: 50,
});

// Get workflow runs for a PR
const prRuns = await convex.query(api.github_workflows.getWorkflowRunsForPr, {
  teamId: "team-id",
  repoFullName: "owner/repo",
  prNumber: 123,
});
```

## Features:

- **Real-time sync**: Workflow runs are synced in real-time via webhooks
- **Comprehensive data**: Stores run metadata, timing, status, conclusion, and PR associations
- **Efficient querying**: Indexed for fast lookups by team, repo, workflow, and PR
- **Type safety**: Full TypeScript support with proper schema validation
- **Security**: Maintains existing webhook signature verification
- **Extensible**: Ready for future workflow job tracking

## Next Steps:

1. **Historical backfill**: Implement the `backfillWorkflowRuns` function to fetch historical runs
2. **Workflow job tracking**: Add support for `workflow_job` events to track individual job details
3. **UI integration**: Build frontend components to display workflow run data
4. **Analytics**: Add aggregation functions for workflow run statistics
5. **Notifications**: Add alerts for workflow run failures or long-running jobs
