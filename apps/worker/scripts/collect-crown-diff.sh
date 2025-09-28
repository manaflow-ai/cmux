#!/usr/bin/env bash
set -euo pipefail

# Collect a filtered git patch between two refs with ignore rules.
# - Compares against the default branch on origin (origin/HEAD),
#   or CMUX_DIFF_BASE when provided.
# - Allows overriding the head ref via CMUX_DIFF_HEAD_REF (default HEAD).
# - Excludes lockfiles, build artifacts, vendor dirs, VCS, common binary/image types.
# - Skips very large files (> CMUX_DIFF_MAX_SIZE_BYTES, default 200000 bytes).
# - Includes modifications, additions, deletions, and renames.

export GIT_PAGER=cat
export PAGER=cat

MAX_SIZE=${CMUX_DIFF_MAX_SIZE_BYTES:-200000}

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "${repo_root}" ]]; then
  echo "Not a git repository" >&2
  exit 1
fi

cd "${repo_root}"

is_ignored_path() {
  local p="$1"
  case "$p" in
    .git/*|.git) return 0 ;;
    node_modules/*|pnpm-lock.yaml|yarn.lock|package-lock.json|*.map|dist/*|build/*|.next/*|out/*|.turbo/*) return 0 ;;
    venv/*|.venv/*|__pycache__/*|Pipfile.lock|poetry.lock) return 0 ;;
    Gemfile.lock|composer.lock|vendor/*) return 0 ;;
    target/*|Cargo.lock) return 0 ;;
    coverage/*|.nyc_output/*) return 0 ;;
    *.min.js|*.min.css|*.log|*.tmp|*.cache|.DS_Store) return 0 ;;
    *.png|*.jpg|*.jpeg|*.gif|*.svg|*.ico|*.webp|*.bmp|*.pdf|*.zip|*.tar|*.tar.gz|*.tgz|*.gz|*.xz|*.bz2|*.7z|*.mp4|*.mp3|*.avi) return 0 ;;
  esac
  return 1
}

# Determine the base ref on origin
determine_base_ref() {
  if [[ -n "${CMUX_DIFF_BASE:-}" ]]; then
    echo "${CMUX_DIFF_BASE}"
    return 0
  fi

  if git rev-parse --git-dir >/dev/null 2>&1 && git remote get-url origin >/dev/null 2>&1; then
    git fetch --quiet --prune origin 2>/dev/null || true
  fi

  local origin_head
  origin_head=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [[ -n "$origin_head" ]]; then
    echo "$origin_head"
    return 0
  fi

  echo ""
}

base_ref=$(determine_base_ref)
head_ref=${CMUX_DIFF_HEAD_REF:-HEAD}

if [[ -n "$base_ref" ]]; then
  if [[ "$base_ref" == origin/* ]]; then
    git fetch --quiet origin "${base_ref#origin/}" >/dev/null 2>&1 || true
  fi
  if [[ "$head_ref" == origin/* ]]; then
    git fetch --quiet origin "${head_ref#origin/}" >/dev/null 2>&1 || true
  fi

  merge_base=$(git merge-base "$base_ref" "$head_ref" 2>/dev/null || echo "")
  if [[ -z "$merge_base" ]]; then
    echo "Could not determine merge-base" >&2
    exit 1
  fi

  if [[ "$head_ref" == HEAD ]]; then
    has_uncommitted=false
    if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
      has_uncommitted=true
    fi

    if [[ "$has_uncommitted" == true ]]; then
      changed_tracked=$(git --no-pager diff --name-only "$merge_base" || true)
      untracked=$(git ls-files --others --exclude-standard || true)
      filtered_files=()
      OIFS="$IFS"; IFS=$'\n'
      for f in $changed_tracked; do
        [[ -n "$f" ]] || continue
        if is_ignored_path "$f"; then continue; fi
        size=0
        if [[ -f "$f" ]]; then
          size=$(wc -c <"$f" 2>/dev/null || echo 0)
        elif [[ -n "$merge_base" ]]; then
          size=$(git cat-file -s "$merge_base:$f" 2>/dev/null || echo 0)
        fi
        case "$size" in
          ''|*[!0-9]*) size=0 ;;
        esac
        if [[ "$size" -gt "$MAX_SIZE" ]]; then continue; fi
        filtered_files+=("$f")
      done
      for f in $untracked; do
        [[ -n "$f" ]] || continue
        if is_ignored_path "$f"; then continue; fi
        if [[ -f "$f" ]]; then
          size=$(wc -c <"$f" 2>/dev/null || echo 0)
          case "$size" in
            ''|*[!0-9]*) size=0 ;;
          esac
          if [[ "$size" -gt "$MAX_SIZE" ]]; then continue; fi
        fi
        filtered_files+=("$f")
      done
      IFS="$OIFS"

      if [[ ${#filtered_files[@]} -eq 0 ]]; then
        exit 0
      fi

      tmp_index=$(mktemp)
      rm -f "$tmp_index" || true
      trap 'rm -f "$tmp_index"' EXIT
      export GIT_INDEX_FILE="$tmp_index"
      git read-tree HEAD
      for f in "${filtered_files[@]}"; do
        if [[ -f "$f" ]]; then
          git add -- "$f" 2>/dev/null || true
        fi
      done
      git --no-pager diff --staged -M --no-color "$merge_base" || true
      unset GIT_INDEX_FILE
    else
      changed_files=$(git --no-pager diff --name-only "$merge_base" HEAD || true)
      filtered_files=()
      OIFS="$IFS"; IFS=$'\n'
      for f in $changed_files; do
        [[ -n "$f" ]] || continue
        if is_ignored_path "$f"; then continue; fi
        size=0
        if git cat-file -e "HEAD:$f" 2>/dev/null; then
          size=$(git cat-file -s "HEAD:$f" 2>/dev/null || echo 0)
        elif git cat-file -e "$merge_base:$f" 2>/dev/null; then
          size=$(git cat-file -s "$merge_base:$f" 2>/dev/null || echo 0)
        fi
        case "$size" in
          ''|*[!0-9]*) size=0 ;;
        esac
        if [[ "$size" -gt "$MAX_SIZE" ]]; then continue; fi
        filtered_files+=("$f")
      done
      IFS="$OIFS"

      if [[ ${#filtered_files[@]} -eq 0 ]]; then
        exit 0
      fi

      git --no-pager diff -M --no-color "$merge_base" HEAD -- "${filtered_files[@]}" || true
    fi
  else
    changed_files=$(git --no-pager diff --name-only "$merge_base" "$head_ref" || true)
    filtered_files=()
    OIFS="$IFS"; IFS=$'\n'
    for f in $changed_files; do
      [[ -n "$f" ]] || continue
      if is_ignored_path "$f"; then continue; fi
      size=0
      if git cat-file -e "$head_ref:$f" 2>/dev/null; then
        size=$(git cat-file -s "$head_ref:$f" 2>/dev/null || echo 0)
      elif git cat-file -e "$merge_base:$f" 2>/dev/null; then
        size=$(git cat-file -s "$merge_base:$f" 2>/dev/null || echo 0)
      fi
      case "$size" in
        ''|*[!0-9]*) size=0 ;;
      esac
      if [[ "$size" -gt "$MAX_SIZE" ]]; then continue; fi
      filtered_files+=("$f")
    done
    IFS="$OIFS"

    if [[ ${#filtered_files[@]} -eq 0 ]]; then
      exit 0
    fi

    git --no-pager diff -M --no-color "$merge_base" "$head_ref" -- "${filtered_files[@]}" || true
  fi

  exit 0
fi

tracked=$(git --no-pager diff --name-only || true)
staged_mods=$(git --no-pager diff --name-only --cached || true)
untracked=$(git ls-files --others --exclude-standard || true)
deleted_list=$( (git --no-pager diff --name-only --diff-filter=D; git ls-files --deleted) 2>/dev/null | sort -u || true )

tmp_index=$(mktemp)
rm -f "$tmp_index" || true
trap 'rm -f "$tmp_index"' EXIT
export GIT_INDEX_FILE="$tmp_index"

{
  echo "$tracked"
  echo "$staged_mods"
  echo "$untracked"
} | while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if is_ignored_path "$f"; then continue; fi
  if [[ -f "$f" ]]; then
    size=$(wc -c <"$f" 2>/dev/null || echo 0)
    case "$size" in
      ''|*[!0-9]*) size=0 ;;
    esac
    if [[ "$size" -gt "$MAX_SIZE" ]]; then continue; fi
  fi
  git add -- "$f" 2>/dev/null || true
done

echo "$deleted_list" | while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if is_ignored_path "$f"; then continue; fi
  git update-index --remove -- "$f" 2>/dev/null || true
done

git --no-pager diff --staged --no-color || true
