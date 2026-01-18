/// <reference lib="webworker" />

import {
  buildCommandSearchIndex,
  filterCommandItemsWithIndex,
  type CommandSearchIndex,
  type SearchableCommandItem,
} from "./commandSearch";

type CommandSearchWorkerRequest = {
  id: number;
  datasetKey: number;
  query: string;
  limit?: number;
  items?: SearchableCommandItem[];
};

type CommandSearchWorkerResponse = {
  id: number;
  values: string[];
  error?: string;
};

type DatasetCacheEntry = {
  index: CommandSearchIndex<SearchableCommandItem>;
};

const datasetCache = new Map<number, DatasetCacheEntry>();

declare const self: DedicatedWorkerGlobalScope;

self.onmessage = (event: MessageEvent<CommandSearchWorkerRequest>) => {
  const { id, datasetKey, query, items, limit } = event.data;
  try {
    if (items) {
      datasetCache.set(datasetKey, {
        index: buildCommandSearchIndex(items),
      });
    }

    const dataset = datasetCache.get(datasetKey);
    if (!dataset) {
      throw new Error(`No search dataset cached for key ${datasetKey}`);
    }

    const filtered = filterCommandItemsWithIndex(query, dataset.index, {
      limit,
    });
    const values = filtered.map((item) => item.value);
    const response: CommandSearchWorkerResponse = { id, values };
    self.postMessage(response);
  } catch (error) {
    const response: CommandSearchWorkerResponse = {
      id,
      values: [],
      error: error instanceof Error ? error.message : String(error),
    };
    self.postMessage(response);
  }
};

export {};
