import type { Answer, Sources } from './app.contract.d.ts';

export const grants = '';

const sources: Sources = {
  loadWorkspaces: () => [
    { id: 'cmux', name: 'cmux', detail: 'feat-cmux-next · Claude Code working', meta: '6 tabs' },
    { id: 'platform', name: 'cmux-platform', detail: 'main · Codex idle', meta: '3 tabs' },
    { id: 'ghostty', name: 'ghostty', detail: 'main · mini-cmuxs-mac-mini-2', meta: '2 tabs' },
    { id: 'android', name: 'cmux-next-android', detail: 'feat-android · Claude Code working', meta: '4 tabs' },
  ],
  loadDms: () => [
    { id: 'chief', name: 'Chief', detail: 'Two agents are working; one is waiting on you.', meta: 'now' },
    { id: 'cc', name: 'Claude Code · cmux', detail: 'Run the iOS kit tests before pushing?', meta: '2m' },
    { id: 'codex', name: 'Codex · cmux-platform', detail: 'Migrated device registry. Tests green.', meta: '11m' },
    { id: 'austin', name: 'Austin', detail: 'can you look at the sidebar PR?', meta: '1h' },
  ],
  loadFeed: () => [
    { id: 'ask', name: 'Needs your answer', detail: 'Run the iOS kit tests on the fleet Mac before pushing?', meta: 'Claude Code · cmux · 2m' },
    { id: 'done', name: 'Finished', detail: 'Migrated device registry to Hyperdrive. 14 files changed, tests green.', meta: 'Codex · cmux-platform · 11m' },
  ],
  loadSettings: () => [
    { id: 'acct', name: 'Account', detail: 'lawrence@manaflow.ai', meta: '' },
    { id: 'team', name: 'Team', detail: 'Manaflow', meta: '' },
    { id: 'macs', name: 'Paired Macs', detail: '2', meta: '' },
    { id: 'ver', name: 'Version', detail: '0.1.0 (Exact, mock data)', meta: '' },
  ],
};
export const answer: Answer = (source, args, store, storage, native) => sources[source](args, store, storage, native);
