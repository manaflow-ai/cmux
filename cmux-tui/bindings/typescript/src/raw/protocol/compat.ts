import type {
  CmuxRequestParams,
  CmuxResponseDataFor,
  Id,
  JsonValue,
  WorkspaceMutationResult,
} from "../generated/index.js";

/** Wire command ids are numeric uint64 values. Short ids are CLI-only. */
export type IdRef = Id;
export type Json = JsonValue;
export type CopyMode = CmuxRequestParams<"copy">["mode"];
export type IdKind = NonNullable<CmuxRequestParams<"ids">["kind"]>;
export type WorkspaceMutation = WorkspaceMutationResult;
export type WorkspacePlacement = CmuxResponseDataFor<"create-workspace">;
