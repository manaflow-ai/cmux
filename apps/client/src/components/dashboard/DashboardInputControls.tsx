import AntdMultiSelect from "@/components/AntdMultiSelect";
import { ModeToggleTooltip } from "@/components/ui/mode-toggle-tooltip";
import { AGENT_CONFIGS } from "@cmux/shared/agentConfig";
import clsx from "clsx";
import { Image, Mic } from "lucide-react";
import { memo, useCallback, useMemo } from "react";

interface DashboardInputControlsProps {
  projectOptions: string[];
  selectedProject: string[];
  onProjectChange: (projects: string[]) => void;
  branchOptions: string[];
  selectedBranch: string[];
  onBranchChange: (branches: string[]) => void;
  selectedAgents: string[];
  onAgentChange: (agents: string[]) => void;
  isCloudMode: boolean;
  onCloudModeToggle: () => void;
  isLoadingProjects: boolean;
  isLoadingBranches: boolean;
  teamSlugOrId: string;
}

export const DashboardInputControls = memo(function DashboardInputControls({
  projectOptions,
  selectedProject,
  onProjectChange,
  branchOptions,
  selectedBranch,
  onBranchChange,
  selectedAgents,
  onAgentChange,
  isCloudMode,
  onCloudModeToggle,
  isLoadingProjects,
  isLoadingBranches,
  teamSlugOrId,
}: DashboardInputControlsProps) {
  const agentOptions = useMemo(
    () => AGENT_CONFIGS.map((agent) => agent.name),
    []
  );
  // Determine OS for potential future UI tweaks
  // const isMac = navigator.userAgent.toUpperCase().indexOf("MAC") >= 0;

  const handleImageClick = useCallback(() => {
    // Trigger the file select from ImagePlugin
    const lexicalWindow = window as Window & {
      __lexicalImageFileSelect?: () => void;
    };
    if (lexicalWindow.__lexicalImageFileSelect) {
      lexicalWindow.__lexicalImageFileSelect();
    }
  }, []);

  return (
    <div className="flex items-end gap-1 grow">
      <div className="flex items-end gap-1">
        <AntdMultiSelect
          options={projectOptions}
          value={selectedProject}
          onChange={onProjectChange}
          placeholder="Select project"
          singleSelect={true}
          className="!min-w-[300px] !max-w-[500px] !rounded-2xl"
          loading={isLoadingProjects}
          maxTagCount={1}
          showSearch
        />

        <AntdMultiSelect
          options={branchOptions}
          value={selectedBranch}
          onChange={onBranchChange}
          placeholder="Branch"
          singleSelect={true}
          className="!min-w-[120px] !rounded-2xl"
          loading={isLoadingBranches}
          showSearch
        />

        <AntdMultiSelect
          options={agentOptions}
          value={selectedAgents}
          onChange={onAgentChange}
          placeholder="Select agents"
          singleSelect={false}
          maxTagCount={1}
          className="!w-[220px] !max-w-[220px] !rounded-2xl"
          showSearch
        />
      </div>

      <div className="flex items-center justify-end gap-2.5 ml-auto mr-0 pr-1">
        {/* Cloud/Local Mode Toggle */}
        <ModeToggleTooltip
          isCloudMode={isCloudMode}
          onToggle={onCloudModeToggle}
          teamSlugOrId={teamSlugOrId}
        />

        <button
          className={clsx(
            "p-1.5 rounded-full",
            "bg-neutral-100 dark:bg-neutral-700",
            "border border-neutral-200 dark:border-0",
            "text-neutral-600 dark:text-neutral-400",
            "hover:bg-neutral-200 dark:hover:bg-neutral-600",
            "transition-colors"
          )}
          onClick={handleImageClick}
          title="Upload image"
        >
          <Image className="w-4 h-4" />
        </button>

        <button
          className={clsx(
            "p-1.5 rounded-full",
            "bg-neutral-100 dark:bg-neutral-700",
            "border border-neutral-200 dark:border-0",
            "text-neutral-600 dark:text-neutral-400",
            "hover:bg-neutral-200 dark:hover:bg-neutral-600",
            "transition-colors"
          )}
        >
          <Mic className="w-4 h-4" />
        </button>
      </div>
    </div>
  );
});
