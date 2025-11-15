import { useCallback, useEffect, useRef } from "react";

import {
  buildCommandSearchIndex,
  filterCommandItemsWithIndex,
  type CommandSearchIndex,
  type SearchableCommandItem,
} from "./commandSearch";

type CommandSearchWorkerParams = {
  datasetKey: number;
  query: string;
  items?: SearchableCommandItem[];
  limit?: number;
  index?: CommandSearchIndex<SearchableCommandItem>;
};

type CommandSearchWorkerRequest = Omit<CommandSearchWorkerParams, "index"> & {
  id: number;
};

type CommandSearchWorkerResponse = {
  id: number;
  values: string[];
  error?: string;
};

type PendingResolver = {
  resolve: (values: string[]) => void;
  reject: (error: unknown) => void;
};

const createFallbackResult = (params: CommandSearchWorkerParams): string[] => {
  const index =
    params.index ??
    buildCommandSearchIndex<SearchableCommandItem>(params.items ?? []);
  const filtered = filterCommandItemsWithIndex(params.query, index, {
    limit: params.limit,
  });
  return filtered.map((entry) => entry.value);
};

export type RunCommandSearch = (
  params: CommandSearchWorkerParams,
) => Promise<string[]>;

export const useCommandSearchWorker = (): RunCommandSearch => {
  const workerRef = useRef<Worker | null>(null);
  const nextRequestIdRef = useRef(0);
  const pendingResolversRef = useRef<Map<number, PendingResolver>>(new Map());

  useEffect(() => {
    if (typeof window === "undefined") {
      return undefined;
    }

    const worker = new Worker(
      new URL("./commandSearchWorker.ts", import.meta.url),
      {
        type: "module",
      },
    );
    workerRef.current = worker;

    const handleMessage = (event: MessageEvent<CommandSearchWorkerResponse>) => {
      const { id, values, error } = event.data;
      const pending = pendingResolversRef.current.get(id);
      if (!pending) {
        return;
      }
      pendingResolversRef.current.delete(id);
      if (error) {
        pending.reject(new Error(error));
        return;
      }
      pending.resolve(values);
    };

    const handleError = (event: ErrorEvent) => {
      console.error("Command search worker error", event);
    };

    worker.addEventListener("message", handleMessage);
    worker.addEventListener("error", handleError);

    const resolverMap = pendingResolversRef.current;
    return () => {
      worker.removeEventListener("message", handleMessage);
      worker.removeEventListener("error", handleError);
      worker.terminate();
      workerRef.current = null;

      resolverMap.forEach(({ reject }) => {
        reject(new Error("Command search worker terminated"));
      });
      resolverMap.clear();
    };
  }, []);

  return useCallback(
    (params: CommandSearchWorkerParams) => {
      const worker = workerRef.current;
      if (!worker) {
        return Promise.resolve(createFallbackResult(params));
      }

      const id = nextRequestIdRef.current++;
      return new Promise<string[]>((resolve, reject) => {
        pendingResolversRef.current.set(id, { resolve, reject });
        const { index: _index, ...rest } = params;
        const request: CommandSearchWorkerRequest = { ...rest, id };
        worker.postMessage(request);
      });
    },
    [],
  );
};
