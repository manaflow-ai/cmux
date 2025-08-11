export const prePushHook = `#!/bin/bash
# pre-push hook to prevent dangerous operations

protected_branches="main master develop production staging"
remote="$1"
url="$2"

while read local_ref local_sha remote_ref remote_sha
do
    # Extract branch name from ref
    if [[ "$remote_ref" =~ refs/heads/(.+) ]]; then
        branch_name="\${BASH_REMATCH[1]}"
        
        # Check if trying to push to protected branch
        for protected in $protected_branches; do
            if [[ "$branch_name" == "$protected" ]]; then
                echo "Error: Pushing to protected branch '$branch_name' is not allowed from this worktree."
                echo "Please create a pull request instead."
                exit 1
            fi
        done
        
        # Check for force push (remote SHA exists and is different from expected)
        if [ "$remote_sha" != "0000000000000000000000000000000000000000" ]; then
            # Get the common ancestor
            common_ancestor=$(git merge-base "$remote_sha" "$local_sha" 2>/dev/null || true)
            
            # If remote SHA is not an ancestor of local SHA, it's a force push
            if [ -n "$common_ancestor" ] && [ "$common_ancestor" != "$remote_sha" ]; then
                echo "Error: Force push detected to branch '$branch_name'."
                echo "Force pushing is not allowed from this worktree."
                exit 1
            fi
        fi
    fi
    
    # Prevent branch deletion (local SHA is zero)
    if [ "$local_sha" = "0000000000000000000000000000000000000000" ]; then
        echo "Error: Branch deletion is not allowed from this worktree."
        echo "Please delete branches through the web interface or main repository."
        exit 1
    fi
done

exit 0
`;

export const preCommitHook = `#!/bin/bash
# pre-commit hook to ensure commits are made to appropriate branches

current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
protected_branches="main master develop production staging"

# Check if on a protected branch
for protected in $protected_branches; do
    if [[ "$current_branch" == "$protected" ]]; then
        echo "Error: Direct commits to protected branch '$current_branch' are not allowed."
        echo "Please create a feature branch and submit a pull request."
        exit 1
    fi
done

exit 0
`;

export interface GitHooksConfig {
  protectedBranches?: string[];
  allowForcePush?: boolean;
  allowBranchDeletion?: boolean;
}

export function generatePrePushHook(config: GitHooksConfig = {}): string {
  const protectedBranches = config.protectedBranches?.join(' ') || 'main master develop production staging';
  const allowForcePush = config.allowForcePush ?? false;
  const allowBranchDeletion = config.allowBranchDeletion ?? false;

  let hook = `#!/bin/bash
# pre-push hook to prevent dangerous operations

protected_branches="${protectedBranches}"
remote="$1"
url="$2"

while read local_ref local_sha remote_ref remote_sha
do
    # Extract branch name from ref
    if [[ "$remote_ref" =~ refs/heads/(.+) ]]; then
        branch_name="\${BASH_REMATCH[1]}"
        
        # Check if trying to push to protected branch
        for protected in $protected_branches; do
            if [[ "$branch_name" == "$protected" ]]; then
                echo "Error: Pushing to protected branch '$branch_name' is not allowed from this worktree."
                echo "Please create a pull request instead."
                exit 1
            fi
        done
`;

  if (!allowForcePush) {
    hook += `
        # Check for force push (remote SHA exists and is different from expected)
        if [ "$remote_sha" != "0000000000000000000000000000000000000000" ]; then
            # Get the common ancestor
            common_ancestor=$(git merge-base "$remote_sha" "$local_sha" 2>/dev/null || true)
            
            # If remote SHA is not an ancestor of local SHA, it's a force push
            if [ -n "$common_ancestor" ] && [ "$common_ancestor" != "$remote_sha" ]; then
                echo "Error: Force push detected to branch '$branch_name'."
                echo "Force pushing is not allowed from this worktree."
                exit 1
            fi
        fi`;
  }

  hook += `
    fi`;

  if (!allowBranchDeletion) {
    hook += `
    
    # Prevent branch deletion (local SHA is zero)
    if [ "$local_sha" = "0000000000000000000000000000000000000000" ]; then
        echo "Error: Branch deletion is not allowed from this worktree."
        echo "Please delete branches through the web interface or main repository."
        exit 1
    fi`;
  }

  hook += `
done

exit 0
`;

  return hook;
}

export function generatePreCommitHook(config: GitHooksConfig = {}): string {
  const protectedBranches = config.protectedBranches?.join(' ') || 'main master develop production staging';

  return `#!/bin/bash
# pre-commit hook to ensure commits are made to appropriate branches

current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
protected_branches="${protectedBranches}"

# Check if on a protected branch
for protected in $protected_branches; do
    if [[ "$current_branch" == "$protected" ]]; then
        echo "Error: Direct commits to protected branch '$current_branch' are not allowed."
        echo "Please create a feature branch and submit a pull request."
        exit 1
    fi
done

exit 0
`;
}