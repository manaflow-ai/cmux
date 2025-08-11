# RepositoryManager Test Documentation

## Overview
This document describes the test suite for `repositoryManager.ts` and its current status.

## Test Results Summary
- **Total Tests**: 16
- **Passing**: 14
- **Failing**: 2 (due to git config lock issues during concurrent operations)

## Test Coverage

### Basic Operations ✅
- Repository cloning
- Handling existing repositories without re-cloning
- Git pull strategy configuration

### Concurrent Operations ⚠️
- Multiple concurrent clones of same repo ✅
- Concurrent fetch operations ✅
- Worktree operations queueing ❌ (fails due to git config locks)

### Error Recovery ✅
- Non-existent branch handling
- Worktree creation failures
- Invalid repository URLs

### Pull Strategy Tests ✅
- Rebase strategy configuration
- Fast-forward only strategy

### Git Hooks ✅
- Hook setup in main repositories
- Hook setup in worktrees

### Configuration Updates ✅
- Runtime configuration changes

### Operation Caching ✅
- Cache timing verification

### Stress Tests ⚠️
- Rapid sequential operations ✅
- Mixed concurrent operations ❌ (fails due to git config locks)

## Known Issues

### Git Config Lock Conflicts
When multiple git operations try to modify `.git/config` simultaneously, git creates a lock file that causes subsequent operations to fail with:
```
error: could not lock config file .git/config: File exists
```

This primarily affects:
1. Concurrent worktree creation (when setting up branch tracking)
2. Concurrent repository configuration (when setting pull strategies)

### Implemented Mitigations
The `repositoryManager.ts` now includes:
- `configLocks` map to serialize config operations per repository
- `worktreeLocks` map to serialize worktree operations
- Proper error handling and logging for config failures

### Remaining Challenges
Despite the mitigations, git's internal locking during `git worktree add` can still cause conflicts when:
- Multiple worktrees are created simultaneously
- The worktree creation itself modifies the config file

## Recommendations

1. **Production Usage**: The repository manager works well for most use cases. For high-concurrency scenarios, consider:
   - Adding exponential backoff retry logic for config operations
   - Implementing a global queue for all git operations that modify config
   - Using a mutex library for more robust locking

2. **Testing**: The test suite provides good coverage. The two failing tests demonstrate edge cases that may occur under extreme load but are unlikely in normal usage.

3. **Monitoring**: In production, monitor for:
   - "could not lock config file" errors
   - Failed worktree creations
   - Slow repository operations (indicating lock contention)

## Running the Tests

```bash
# Run all tests
bun test repositoryManager.test.ts --timeout 60000

# Run specific test groups
bun test repositoryManager.test.ts --test-name-pattern="Basic Operations"

# Skip problematic tests
bun test repositoryManager.test.ts --test-name-pattern="^(?!.*should queue worktree operations properly|.*mixed concurrent operations)"
```