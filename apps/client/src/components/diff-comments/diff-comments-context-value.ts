import { createContext } from "react";
import type { DiffCommentsContextValue } from "./types";

export const DiffCommentsContext = createContext<DiffCommentsContextValue | null>(null);
