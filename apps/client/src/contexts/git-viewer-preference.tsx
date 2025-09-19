import {
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useMemo,
  useState,
} from "react";

export type GitViewerPreference = "monaco" | "codemirror";

interface GitViewerPreferenceContextValue {
  viewer: GitViewerPreference;
  setViewer: (viewer: GitViewerPreference) => void;
  toggleViewer: () => void;
}

const GitViewerPreferenceContext =
  createContext<GitViewerPreferenceContextValue | null>(null);

interface GitViewerPreferenceProviderProps {
  children: ReactNode;
}

export function GitViewerPreferenceProvider({
  children,
}: GitViewerPreferenceProviderProps) {
  const [viewer, setViewer] = useState<GitViewerPreference>("monaco");

  const toggleViewer = useCallback(() => {
    setViewer((prev) => (prev === "monaco" ? "codemirror" : "monaco"));
  }, []);

  const value = useMemo(
    () => ({
      viewer,
      setViewer,
      toggleViewer,
    }),
    [viewer, toggleViewer]
  );

  return (
    <GitViewerPreferenceContext.Provider value={value}>
      {children}
    </GitViewerPreferenceContext.Provider>
  );
}

// eslint-disable-next-line react-refresh/only-export-components
export function useGitViewerPreference(): GitViewerPreferenceContextValue {
  const context = useContext(GitViewerPreferenceContext);
  if (!context) {
    return {
      viewer: "monaco",
      setViewer: () => {},
      toggleViewer: () => {},
    };
  }
  return context;
}
